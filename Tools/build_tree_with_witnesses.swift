#!/usr/bin/env swift
//
// build_tree_with_witnesses.swift
// Builds Sapling commitment tree and generates witnesses for notes
// Uses local zclassicd node and ZipherX Rust FFI
//
// Usage: swift build_tree_with_witnesses.swift [ivk_hex] [rpc_user] [rpc_password] [rpc_port]
//

import Foundation

// MARK: - FFI Declarations

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

@_silgen_name("zipherx_tree_witness_current")
func zipherx_tree_witness_current() -> UInt64

@_silgen_name("zipherx_tree_get_witness")
func zipherx_tree_get_witness(_ witness_index: UInt64, _ witness_out: UnsafeMutablePointer<UInt8>) -> Bool

@_silgen_name("zipherx_try_decrypt_note")
func zipherx_try_decrypt_note(
    _ ivk: UnsafePointer<UInt8>,
    _ epk: UnsafePointer<UInt8>,
    _ cmu: UnsafePointer<UInt8>,
    _ enc_ciphertext: UnsafePointer<UInt8>,
    _ diversifier_out: UnsafeMutablePointer<UInt8>,
    _ value_out: UnsafeMutablePointer<UInt64>,
    _ rcm_out: UnsafeMutablePointer<UInt8>,
    _ memo_out: UnsafeMutablePointer<UInt8>
) -> Bool

// MARK: - Configuration

struct Config {
    let rpcUser: String
    let rpcPassword: String
    let rpcHost: String
    let rpcPort: Int
    let saplingActivation: UInt64 = 559500
    let ivk: Data

    var rpcURL: URL {
        URL(string: "http://\(rpcHost):\(rpcPort)")!
    }

    var authString: String {
        let credentials = "\(rpcUser):\(rpcPassword)"
        return Data(credentials.utf8).base64EncodedString()
    }
}

// MARK: - RPC Types

struct RPCResponse<R: Decodable>: Decodable {
    let result: R?
    let error: RPCErrorInfo?
}

struct RPCErrorInfo: Decodable {
    let code: Int
    let message: String
}

struct BlockData: Decodable {
    let hash: String
    let height: Int
    let tx: [TransactionData]
}

struct TransactionData: Decodable {
    let txid: String
    let vShieldedOutput: [ShieldedOutput]?
}

struct ShieldedOutput: Decodable {
    let cmu: String
    let cv: String
    let encCiphertext: String
    let ephemeralKey: String
    let proof: String
}

// MARK: - RPC Client

class ZclassicRPC {
    let config: Config
    private var requestId = 0

    init(config: Config) {
        self.config = config
    }

    func call<T: Decodable>(method: String, params: [Any] = []) async throws -> T {
        requestId += 1

        var request = URLRequest(url: config.rpcURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Basic \(config.authString)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "jsonrpc": "1.0",
            "id": requestId,
            "method": method,
            "params": params
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw NSError(domain: "RPC", code: -1, userInfo: [NSLocalizedDescriptionKey: "HTTP error"])
        }

        let rpcResponse = try JSONDecoder().decode(RPCResponse<T>.self, from: data)

        if let error = rpcResponse.error {
            throw NSError(domain: "RPC", code: error.code, userInfo: [NSLocalizedDescriptionKey: error.message])
        }

        guard let result = rpcResponse.result else {
            throw NSError(domain: "RPC", code: -1, userInfo: [NSLocalizedDescriptionKey: "No result"])
        }

        return result
    }

    func getBlockCount() async throws -> UInt64 {
        try await call(method: "getblockcount")
    }

    func getBlockHash(height: UInt64) async throws -> String {
        try await call(method: "getblockhash", params: [height])
    }

    func getBlock(hash: String) async throws -> BlockData {
        try await call(method: "getblock", params: [hash, 2])
    }
}

// MARK: - Note Info

struct FoundNote {
    let position: UInt64
    let witnessIndex: UInt64
    let value: UInt64
    let diversifier: Data
    let rcm: Data
    let txid: String
    let height: UInt64
}

// MARK: - Main

func main() async {
    print("🌳 Building Sapling Tree with Witnesses")
    print("=======================================\n")

    let args = CommandLine.arguments

    guard args.count > 1 else {
        print("Usage: swift build_tree_with_witnesses.swift <ivk_hex> [rpc_user] [rpc_password] [rpc_port]")
        print("\nTo get your IVK, use your spending key and the wallet's key derivation.")
        exit(1)
    }

    let ivkHex = args[1]
    guard let ivkData = Data(hexString: ivkHex), ivkData.count == 32 else {
        print("❌ Invalid IVK - must be 32 bytes hex")
        exit(1)
    }

    let rpcUser = args.count > 2 ? args[2] : "zcluser_oA7WuCX1"
    let rpcPassword = args.count > 3 ? args[3] : "bRZUaCFkRuuZpbRX2b3TQcaUFlNFT2TZ"
    let rpcPort = args.count > 4 ? Int(args[4]) ?? 8232 : 8232

    let config = Config(
        rpcUser: rpcUser,
        rpcPassword: rpcPassword,
        rpcHost: "127.0.0.1",
        rpcPort: rpcPort,
        ivk: ivkData
    )

    print("📡 Connecting to zclassicd at \(config.rpcHost):\(config.rpcPort)")
    print("🔑 Using IVK: \(ivkHex.prefix(16))...")

    let rpc = ZclassicRPC(config: config)

    // Initialize tree
    guard zipherx_tree_init() else {
        print("❌ Failed to initialize tree")
        exit(1)
    }
    print("✅ Tree initialized")

    var foundNotes: [FoundNote] = []

    do {
        let blockCount = try await rpc.getBlockCount()
        print("📊 Current block height: \(blockCount)")

        let startHeight = config.saplingActivation
        let totalBlocks = blockCount - startHeight + 1
        print("📦 Scanning \(totalBlocks) blocks from Sapling activation")
        print("")

        var processedBlocks: UInt64 = 0
        var totalOutputs: UInt64 = 0
        let startTime = Date()
        let batchSize = 100

        var currentHeight = startHeight
        while currentHeight <= blockCount {
            let endHeight = min(currentHeight + UInt64(batchSize) - 1, blockCount)
            let heights = Array(currentHeight...endHeight)

            // Fetch blocks in parallel
            let blocks = try await withThrowingTaskGroup(of: (UInt64, BlockData).self) { group in
                for height in heights {
                    group.addTask {
                        let hash = try await rpc.getBlockHash(height: height)
                        let block = try await rpc.getBlock(hash: hash)
                        return (height, block)
                    }
                }
                var results: [(UInt64, BlockData)] = []
                for try await result in group {
                    results.append(result)
                }
                return results.sorted { $0.0 < $1.0 }
            }

            // Process blocks sequentially (important for tree order!)
            for (height, block) in blocks {
                for tx in block.tx {
                    guard let outputs = tx.vShieldedOutput, !outputs.isEmpty else { continue }

                    for output in outputs {
                        // Parse CMU
                        guard var cmuData = Data(hexString: output.cmu) else { continue }
                        cmuData.reverse() // RPC is big-endian, tree needs little-endian

                        // Append to tree
                        let position = cmuData.withUnsafeBytes { ptr in
                            zipherx_tree_append(ptr.baseAddress!.assumingMemoryBound(to: UInt8.self))
                        }
                        totalOutputs += 1

                        // Try to decrypt
                        guard let epkData = Data(hexString: output.ephemeralKey),
                              let encData = Data(hexString: output.encCiphertext) else { continue }

                        var diversifier = [UInt8](repeating: 0, count: 11)
                        var value: UInt64 = 0
                        var rcm = [UInt8](repeating: 0, count: 32)
                        var memo = [UInt8](repeating: 0, count: 512)

                        let decrypted = config.ivk.withUnsafeBytes { ivkPtr in
                            epkData.withUnsafeBytes { epkPtr in
                                cmuData.withUnsafeBytes { cmuPtr in
                                    encData.withUnsafeBytes { encPtr in
                                        zipherx_try_decrypt_note(
                                            ivkPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                                            epkPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                                            cmuPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                                            encPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                                            &diversifier,
                                            &value,
                                            &rcm,
                                            &memo
                                        )
                                    }
                                }
                            }
                        }

                        if decrypted {
                            // Found our note! Create witness
                            let witnessIndex = zipherx_tree_witness_current()

                            let note = FoundNote(
                                position: position,
                                witnessIndex: witnessIndex,
                                value: value,
                                diversifier: Data(diversifier),
                                rcm: Data(rcm),
                                txid: tx.txid,
                                height: height
                            )
                            foundNotes.append(note)

                            print("\n🎉 Found note at height \(height)!")
                            print("   Value: \(value) zatoshis (\(Double(value) / 100_000_000) ZCL)")
                            print("   Position: \(position)")
                            print("   Txid: \(tx.txid)")
                        }
                    }
                }
                processedBlocks += 1
            }

            // Progress
            let elapsed = Date().timeIntervalSince(startTime)
            let blocksPerSec = Double(processedBlocks) / elapsed
            let remaining = Double(totalBlocks - processedBlocks) / blocksPerSec
            let progress = Double(processedBlocks) / Double(totalBlocks) * 100

            print("\r⏳ \(String(format: "%.1f", progress))% | " +
                  "Block \(endHeight)/\(blockCount) | " +
                  "Outputs: \(totalOutputs) | " +
                  "Notes: \(foundNotes.count) | " +
                  "ETA: \(formatTime(remaining))     ", terminator: "")
            fflush(stdout)

            currentHeight = endHeight + 1
        }

        print("\n\n✅ Scan complete!")
        print("📊 Total shielded outputs: \(totalOutputs)")
        print("🔑 Notes found: \(foundNotes.count)")

        // Get final tree root
        var root = [UInt8](repeating: 0, count: 32)
        zipherx_tree_root(&root)
        let rootHex = root.map { String(format: "%02x", $0) }.joined()
        print("🌳 Final tree root: \(rootHex)")

        // Save tree
        let toolsDir = FileManager.default.currentDirectoryPath
        let maxSize = 50 * 1024 * 1024
        var treeBuffer = [UInt8](repeating: 0, count: maxSize)
        var actualSize = maxSize

        guard zipherx_tree_serialize(&treeBuffer, &actualSize) else {
            print("❌ Failed to serialize tree")
            exit(1)
        }

        let treeData = Data(treeBuffer.prefix(actualSize))
        let treePath = toolsDir + "/sapling_tree_with_witnesses.bin"
        try treeData.write(to: URL(fileURLWithPath: treePath))
        print("💾 Tree saved to: \(treePath)")

        // Save witnesses
        var witnessesData = Data()
        witnessesData.append(contentsOf: withUnsafeBytes(of: UInt64(foundNotes.count)) { Array($0) })

        for note in foundNotes {
            // Note metadata
            witnessesData.append(contentsOf: withUnsafeBytes(of: note.position) { Array($0) })
            witnessesData.append(contentsOf: withUnsafeBytes(of: note.value) { Array($0) })
            witnessesData.append(contentsOf: withUnsafeBytes(of: note.height) { Array($0) })
            witnessesData.append(note.diversifier)
            witnessesData.append(note.rcm)

            // Witness data (1028 bytes)
            var witness = [UInt8](repeating: 0, count: 1028)
            if zipherx_tree_get_witness(note.witnessIndex, &witness) {
                witnessesData.append(contentsOf: witness)
            } else {
                print("⚠️ Failed to get witness for note at position \(note.position)")
            }
        }

        let witnessesPath = toolsDir + "/note_witnesses.bin"
        try witnessesData.write(to: URL(fileURLWithPath: witnessesPath))
        print("💾 Witnesses saved to: \(witnessesPath)")

        // Print summary
        print("\n📋 Notes Summary:")
        var total: UInt64 = 0
        for (i, note) in foundNotes.enumerated() {
            print("  \(i+1). \(note.value) zatoshis at height \(note.height)")
            total += note.value
        }
        print("  Total: \(total) zatoshis (\(Double(total) / 100_000_000) ZCL)")

    } catch {
        print("\n❌ Error: \(error)")
        exit(1)
    }
}

// MARK: - Helpers

extension Data {
    init?(hexString: String) {
        let hex = hexString.hasPrefix("0x") ? String(hexString.dropFirst(2)) : hexString
        guard hex.count % 2 == 0 else { return nil }

        var data = Data()
        var index = hex.startIndex

        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }

        self = data
    }
}

func formatTime(_ seconds: Double) -> String {
    if seconds < 60 {
        return "\(Int(seconds))s"
    } else if seconds < 3600 {
        return "\(Int(seconds / 60))m"
    } else {
        return "\(Int(seconds / 3600))h \(Int((seconds.truncatingRemainder(dividingBy: 3600)) / 60))m"
    }
}

// Run
Task {
    await main()
    exit(0)
}

RunLoop.main.run()
