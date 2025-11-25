#!/usr/bin/env swift
//
// build_commitment_tree.swift
// Tool to build Sapling commitment tree from local zclassicd node
//
// Usage: swift build_commitment_tree.swift [rpc_user] [rpc_password] [rpc_port] [end_height]
//

import Foundation

// MARK: - Configuration

struct Config {
    let rpcUser: String
    let rpcPassword: String
    let rpcHost: String
    let rpcPort: Int
    let saplingActivation: UInt64 = 476969  // Zclassic Sapling activation (from getblockchaininfo)
    let outputFile: String

    var rpcURL: URL {
        URL(string: "http://\(rpcHost):\(rpcPort)")!
    }

    var authString: String {
        let credentials = "\(rpcUser):\(rpcPassword)"
        return Data(credentials.utf8).base64EncodedString()
    }
}

// MARK: - RPC Response Types

struct RPCErrorInfo: Decodable {
    let code: Int
    let message: String
}

struct RPCResponse<R: Decodable>: Decodable {
    let result: R?
    let error: RPCErrorInfo?
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

        guard let httpResponse = response as? HTTPURLResponse else {
            throw RPCError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown"
            throw RPCError.httpError(httpResponse.statusCode, errorText)
        }

        let rpcResponse = try JSONDecoder().decode(RPCResponse<T>.self, from: data)

        if let error = rpcResponse.error {
            throw RPCError.rpcError(error.code, error.message)
        }

        guard let result = rpcResponse.result else {
            throw RPCError.noResult
        }

        return result
    }

    func getBlockCount() async throws -> UInt64 {
        try await call(method: "getblockcount")
    }

    func getBlockHash(height: UInt64) async throws -> String {
        try await call(method: "getblockhash", params: [height])
    }

    func getBlock(hash: String, verbosity: Int = 2) async throws -> BlockData {
        try await call(method: "getblock", params: [hash, verbosity])
    }
}

enum RPCError: Error, LocalizedError {
    case invalidResponse
    case httpError(Int, String)
    case rpcError(Int, String)
    case noResult

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid response"
        case .httpError(let code, let msg): return "HTTP \(code): \(msg)"
        case .rpcError(let code, let msg): return "RPC \(code): \(msg)"
        case .noResult: return "No result"
        }
    }
}

// MARK: - Block Data Structures

struct BlockData: Decodable {
    let hash: String
    let height: Int
    let tx: [TransactionData]
}

struct TransactionData: Decodable {
    let txid: String
    let vShieldedOutput: [ShieldedOutput]?

    enum CodingKeys: String, CodingKey {
        case txid
        case vShieldedOutput = "vShieldedOutput"
    }
}

struct ShieldedOutput: Decodable {
    let cmu: String  // Note commitment (hex)
    let cv: String
    let encCiphertext: String
    let ephemeralKey: String
    let proof: String
}

// MARK: - Tree Builder

class CommitmentTreeBuilder {
    private var commitmentCount: UInt64 = 0
    private var treeData: Data?

    // We'll use the FFI functions via dynamic loading
    // For now, we'll collect CMUs and process them
    private var allCommitments: [Data] = []

    // Track CMUs by block height for mapped output
    private var blockCMUs: [UInt64: [Data]] = [:]
    private var currentBlockHeight: UInt64 = 0

    func setCurrentBlock(_ height: UInt64) {
        currentBlockHeight = height
    }

    func addCommitment(_ cmu: Data) {
        allCommitments.append(cmu)
        commitmentCount += 1

        // Track by block
        if blockCMUs[currentBlockHeight] == nil {
            blockCMUs[currentBlockHeight] = []
        }
        blockCMUs[currentBlockHeight]!.append(cmu)
    }

    var count: UInt64 { commitmentCount }

    func getCommitments() -> [Data] {
        return allCommitments
    }

    func getBlockCMUs() -> [UInt64: [Data]] {
        return blockCMUs
    }
}

// MARK: - Main

func main() async {
    print("🌳 Zclassic Commitment Tree Builder")
    print("===================================\n")

    // Parse arguments or use defaults
    let args = CommandLine.arguments

    let rpcUser = args.count > 1 ? args[1] : "zcluser_oA7WuCX1"
    let rpcPassword = args.count > 2 ? args[2] : "bRZUaCFkRuuZpbRX2b3TQcaUFlNFT2TZ"
    let rpcPort = args.count > 3 ? Int(args[3]) ?? 8023 : 8023
    let customEndHeight: UInt64? = args.count > 4 ? UInt64(args[4]) : nil

    let config = Config(
        rpcUser: rpcUser,
        rpcPassword: rpcPassword,
        rpcHost: "127.0.0.1",
        rpcPort: rpcPort,
        outputFile: "commitment_tree.bin"
    )

    print("📡 Connecting to zclassicd at \(config.rpcHost):\(config.rpcPort)")

    let rpc = ZclassicRPC(config: config)
    let builder = CommitmentTreeBuilder()

    do {
        // Get current block height
        let currentBlockCount = try await rpc.getBlockCount()
        print("📊 Current block height: \(currentBlockCount)")

        // Use custom end height if provided, otherwise current height
        let blockCount = customEndHeight ?? currentBlockCount
        if let custom = customEndHeight {
            print("📊 Building tree up to height: \(custom)")
        }

        let startHeight = config.saplingActivation
        let totalBlocks = blockCount - startHeight + 1
        print("📦 Scanning \(totalBlocks) blocks from Sapling activation (\(startHeight)) to \(blockCount)")
        print("")

        var processedBlocks: UInt64 = 0
        let startTime = Date()
        let batchSize = 1000  // Fetch 1000 blocks in parallel for speed

        // Process blocks in parallel batches
        var currentHeight = startHeight
        while currentHeight <= blockCount {
            let endHeight = min(currentHeight + UInt64(batchSize) - 1, blockCount)
            let heights = Array(currentHeight...endHeight)

            // Fetch all block hashes in parallel
            let hashes = try await withThrowingTaskGroup(of: (UInt64, String).self) { group in
                for height in heights {
                    group.addTask {
                        let hash = try await rpc.getBlockHash(height: height)
                        return (height, hash)
                    }
                }
                var results: [(UInt64, String)] = []
                for try await result in group {
                    results.append(result)
                }
                return results.sorted { $0.0 < $1.0 }
            }

            // Fetch all blocks in parallel
            let blocks = try await withThrowingTaskGroup(of: (UInt64, BlockData).self) { group in
                for (height, hash) in hashes {
                    group.addTask {
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

            // Process blocks in order (important for commitment tree!)
            for (height, block) in blocks {
                builder.setCurrentBlock(height)
                for tx in block.tx {
                    if let outputs = tx.vShieldedOutput {
                        for output in outputs {
                            if var cmuData = Data(hexString: output.cmu) {
                                // Reverse bytes: RPC returns big-endian, tree needs little-endian
                                cmuData.reverse()
                                builder.addCommitment(cmuData)
                            }
                        }
                    }
                }
                processedBlocks += 1
            }

            // Progress update
            let elapsed = Date().timeIntervalSince(startTime)
            let blocksPerSec = Double(processedBlocks) / elapsed
            let remaining = Double(totalBlocks - processedBlocks) / blocksPerSec
            let eta = remaining > 0 ? formatTime(remaining) : "done"

            let progress = Double(processedBlocks) / Double(totalBlocks) * 100
            print("\r⏳ Progress: \(String(format: "%.1f", progress))% | " +
                  "Block \(endHeight)/\(blockCount) | " +
                  "Commitments: \(builder.count) | " +
                  "Speed: \(String(format: "%.0f", blocksPerSec)) blk/s | " +
                  "ETA: \(eta)     ", terminator: "")
            fflush(stdout)

            currentHeight = endHeight + 1
        }

        print("\n")
        print("✅ Scan complete!")
        print("📊 Total commitments: \(builder.count)")

        // Save commitments to file (flat format for tree building)
        let outputPath = FileManager.default.currentDirectoryPath + "/" + config.outputFile

        // Format: [count: UInt64][cmu1: 32 bytes][cmu2: 32 bytes]...
        var outputData = Data()
        var count = builder.count
        outputData.append(Data(bytes: &count, count: 8))

        for cmu in builder.getCommitments() {
            outputData.append(cmu)
        }

        try outputData.write(to: URL(fileURLWithPath: outputPath))
        print("💾 Saved to: \(outputPath)")
        print("📦 File size: \(outputData.count / 1024 / 1024) MB")

        // Save mapped CMUs with height info (for wallet restore)
        let mappedOutputPath = FileManager.default.currentDirectoryPath + "/commitment_tree_mapped.bin"
        var mappedData = Data()

        // Header: [total_cmus: UInt64][total_blocks: UInt64]
        var totalCmus = builder.count
        var totalBlocksWithCmus = UInt64(builder.getBlockCMUs().count)
        mappedData.append(Data(bytes: &totalCmus, count: 8))
        mappedData.append(Data(bytes: &totalBlocksWithCmus, count: 8))

        // For each block with CMUs: [height: UInt64][count: UInt16][cmu1...cmuN]
        for (height, cmus) in builder.getBlockCMUs().sorted(by: { $0.key < $1.key }) {
            var h = height
            var c = UInt16(cmus.count)
            mappedData.append(Data(bytes: &h, count: 8))
            mappedData.append(Data(bytes: &c, count: 2))
            for cmu in cmus {
                mappedData.append(cmu)
            }
        }

        try mappedData.write(to: URL(fileURLWithPath: mappedOutputPath))
        print("💾 Mapped CMUs saved to: \(mappedOutputPath)")
        print("📦 Mapped file size: \(mappedData.count / 1024 / 1024) MB")

        // Also save metadata
        let metadataPath = FileManager.default.currentDirectoryPath + "/commitment_tree_meta.json"
        let metadata: [String: Any] = [
            "version": 1,
            "chain": "zclassic",
            "sapling_activation": config.saplingActivation,
            "end_height": blockCount,
            "commitment_count": builder.count,
            "created_at": ISO8601DateFormatter().string(from: Date())
        ]
        let metadataJSON = try JSONSerialization.data(withJSONObject: metadata, options: .prettyPrinted)
        try metadataJSON.write(to: URL(fileURLWithPath: metadataPath))
        print("📋 Metadata saved to: \(metadataPath)")

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
        return "\(Int(seconds / 60))m \(Int(seconds.truncatingRemainder(dividingBy: 60)))s"
    } else {
        let hours = Int(seconds / 3600)
        let mins = Int((seconds.truncatingRemainder(dividingBy: 3600)) / 60)
        return "\(hours)h \(mins)m"
    }
}

// Run
Task {
    await main()
    exit(0)
}

RunLoop.main.run()
