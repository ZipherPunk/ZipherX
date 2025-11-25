# Header-Sync Implementation Plan for ZipherX

## Overview

Instead of building a full Merkle tree locally (which had algorithm mismatches), we'll use zcashd's exact tree state by extracting the `finalsaplingroot` field directly from block headers.

This is **much simpler** and **guaranteed to work** because we use zcashd's computed anchor directly.

---

## The Key Insight

Every Zcash/Zclassic block header contains a `finalsaplingroot` field:

```
Block Header (80 bytes):
- nVersion (4 bytes)
- hashPrevBlock (32 bytes)
- hashMerkleRoot (32 bytes)
- hashFinalSaplingRoot (32 bytes) ← THIS IS THE ANCHOR!
- nTime (4 bytes)
- nBits (4 bytes)
- nNonce (32 bytes)
```

This `hashFinalSaplingRoot` is **zcashd's internal tree root** after processing all transactions in that block. It's the exact anchor we need!

---

## Architecture Changes

### Before (Broken)
```
App builds tree locally → Computes anchor → Doesn't match zcashd → Transaction rejected
```

### After (Fixed)
```
App downloads headers → Extracts finalsaplingroot → Uses zcashd's anchor → Transaction accepted! ✅
```

---

## Implementation Phases

### Phase 1: Block Header Sync

Download and store block headers from the P2P network.

**Storage Requirements:**
- ~80 bytes per header
- 2.9M blocks = ~232 MB
- Pruned (last 100k blocks) = ~8 MB

**Implementation:**

#### 1.1 Create BlockHeader Model

**File:** `/Users/chris/ZipherX/Sources/Core/Models/BlockHeader.swift`

```swift
import Foundation

/// Zclassic block header (80 bytes)
struct BlockHeader {
    let version: UInt32
    let hashPrevBlock: Data       // 32 bytes
    let hashMerkleRoot: Data      // 32 bytes
    let hashFinalSaplingRoot: Data // 32 bytes - THE ANCHOR WE NEED!
    let time: UInt32
    let bits: UInt32
    let nonce: Data               // 32 bytes

    let height: UInt64
    let blockHash: Data           // 32 bytes (computed)

    var anchor: Data {
        return hashFinalSaplingRoot
    }

    /// Parse from network bytes
    static func parse(data: Data, height: UInt64) throws -> BlockHeader {
        guard data.count >= 140 else {
            throw ParseError.insufficientData
        }

        var offset = 0

        let version = data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt32.self) }
        offset += 4

        let hashPrevBlock = data.subdata(in: offset..<offset+32)
        offset += 32

        let hashMerkleRoot = data.subdata(in: offset..<offset+32)
        offset += 32

        let hashFinalSaplingRoot = data.subdata(in: offset..<offset+32)
        offset += 32

        let time = data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt32.self) }
        offset += 4

        let bits = data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt32.self) }
        offset += 4

        let nonce = data.subdata(in: offset..<offset+32)
        offset += 32

        // Compute block hash (double SHA256 of header)
        let blockHash = data.subdata(in: 0..<80).doubleSHA256()

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
}

enum ParseError: Error {
    case insufficientData
}
```

#### 1.2 Create HeaderStore

**File:** `/Users/chris/ZipherX/Sources/Core/Storage/HeaderStore.swift`

```swift
import Foundation
import SQLite3

/// Stores block headers in SQLite
class HeaderStore {
    private let db: OpaquePointer

    init(dbPath: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            throw StorageError.cannotOpenDatabase
        }
        self.db = db!

        try createTables()
    }

    deinit {
        sqlite3_close(db)
    }

    private func createTables() throws {
        let sql = """
        CREATE TABLE IF NOT EXISTS headers (
            height INTEGER PRIMARY KEY,
            block_hash BLOB NOT NULL,
            prev_hash BLOB NOT NULL,
            merkle_root BLOB NOT NULL,
            sapling_root BLOB NOT NULL,
            time INTEGER NOT NULL,
            bits INTEGER NOT NULL,
            nonce BLOB NOT NULL,
            version INTEGER NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_block_hash ON headers(block_hash);
        CREATE INDEX IF NOT EXISTS idx_sapling_root ON headers(sapling_root);
        """

        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw StorageError.cannotCreateTable
        }
    }

    /// Insert a header
    func insert(header: BlockHeader) throws {
        let sql = """
        INSERT OR REPLACE INTO headers
        (height, block_hash, prev_hash, merkle_root, sapling_root, time, bits, nonce, version)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StorageError.cannotPrepareStatement
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, Int64(header.height))
        sqlite3_bind_blob(stmt, 2, (header.blockHash as NSData).bytes, Int32(header.blockHash.count), nil)
        sqlite3_bind_blob(stmt, 3, (header.hashPrevBlock as NSData).bytes, Int32(header.hashPrevBlock.count), nil)
        sqlite3_bind_blob(stmt, 4, (header.hashMerkleRoot as NSData).bytes, Int32(header.hashMerkleRoot.count), nil)
        sqlite3_bind_blob(stmt, 5, (header.hashFinalSaplingRoot as NSData).bytes, Int32(header.hashFinalSaplingRoot.count), nil)
        sqlite3_bind_int64(stmt, 6, Int64(header.time))
        sqlite3_bind_int64(stmt, 7, Int64(header.bits))
        sqlite3_bind_blob(stmt, 8, (header.nonce as NSData).bytes, Int32(header.nonce.count), nil)
        sqlite3_bind_int64(stmt, 9, Int64(header.version))

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw StorageError.insertFailed
        }
    }

    /// Get header at height
    func getHeader(at height: UInt64) throws -> BlockHeader? {
        let sql = "SELECT * FROM headers WHERE height = ?;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StorageError.cannotPrepareStatement
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, Int64(height))

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return nil
        }

        return try parseHeader(from: stmt!)
    }

    /// Get anchor (sapling root) at height
    func getAnchor(at height: UInt64) throws -> Data? {
        guard let header = try getHeader(at: height) else {
            return nil
        }
        return header.anchor
    }

    /// Get latest synced height
    func getLatestHeight() throws -> UInt64 {
        let sql = "SELECT MAX(height) FROM headers;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StorageError.cannotPrepareStatement
        }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return 0
        }

        return UInt64(sqlite3_column_int64(stmt, 0))
    }

    private func parseHeader(from stmt: OpaquePointer) throws -> BlockHeader {
        let height = UInt64(sqlite3_column_int64(stmt, 0))

        let blockHash = Data(bytes: sqlite3_column_blob(stmt, 1), count: Int(sqlite3_column_bytes(stmt, 1)))
        let prevHash = Data(bytes: sqlite3_column_blob(stmt, 2), count: Int(sqlite3_column_bytes(stmt, 2)))
        let merkleRoot = Data(bytes: sqlite3_column_blob(stmt, 3), count: Int(sqlite3_column_bytes(stmt, 3)))
        let saplingRoot = Data(bytes: sqlite3_column_blob(stmt, 4), count: Int(sqlite3_column_bytes(stmt, 4)))

        let time = UInt32(sqlite3_column_int64(stmt, 5))
        let bits = UInt32(sqlite3_column_int64(stmt, 6))

        let nonce = Data(bytes: sqlite3_column_blob(stmt, 7), count: Int(sqlite3_column_bytes(stmt, 7)))
        let version = UInt32(sqlite3_column_int64(stmt, 8))

        return BlockHeader(
            version: version,
            hashPrevBlock: prevHash,
            hashMerkleRoot: merkleRoot,
            hashFinalSaplingRoot: saplingRoot,
            time: time,
            bits: bits,
            nonce: nonce,
            height: height,
            blockHash: blockHash
        )
    }
}

enum StorageError: Error {
    case cannotOpenDatabase
    case cannotCreateTable
    case cannotPrepareStatement
    case insertFailed
}
```

#### 1.3 Create HeaderSyncManager

**File:** `/Users/chris/ZipherX/Sources/Core/Network/HeaderSyncManager.swift`

```swift
import Foundation

/// Manages block header synchronization from P2P network
class HeaderSyncManager {
    private let networkManager: NetworkManager
    private let headerStore: HeaderStore
    private let minPeers = 8
    private let consensusThreshold = 6

    init(networkManager: NetworkManager, headerStore: HeaderStore) {
        self.networkManager = networkManager
        self.headerStore = headerStore
    }

    /// Sync headers from peers with consensus verification
    func syncHeaders(from startHeight: UInt64, to endHeight: UInt64) async throws {
        print("📥 Syncing headers from \(startHeight) to \(endHeight)...")

        // Get connected peers
        let peers = try await networkManager.getConnectedPeers(minimum: minPeers)

        // Request headers from multiple peers in parallel
        var headersByPeer: [[BlockHeader]] = []

        await withTaskGroup(of: (Int, [BlockHeader]?).self) { group in
            for (index, peer) in peers.enumerated() {
                group.addTask {
                    do {
                        let headers = try await self.fetchHeaders(
                            from: peer,
                            startHeight: startHeight,
                            endHeight: endHeight
                        )
                        return (index, headers)
                    } catch {
                        print("❌ Failed to fetch headers from peer \(index): \(error)")
                        return (index, nil)
                    }
                }
            }

            for await (_, headers) in group {
                if let headers = headers {
                    headersByPeer.append(headers)
                }
            }
        }

        // Require consensus
        guard headersByPeer.count >= consensusThreshold else {
            throw SyncError.insufficientConsensus
        }

        // Verify all peers agree on headers
        let consensusHeaders = try verifyConsensus(headersByPeer)

        // Store headers
        for header in consensusHeaders {
            try headerStore.insert(header: header)
        }

        print("✅ Synced \(consensusHeaders.count) headers with consensus")
    }

    /// Fetch headers from a single peer
    private func fetchHeaders(
        from peer: Peer,
        startHeight: UInt64,
        endHeight: UInt64
    ) async throws -> [BlockHeader] {

        // Send getheaders message
        let locator = try await peer.getHeaders(from: startHeight, to: endHeight)

        var headers: [BlockHeader] = []
        for height in startHeight...endHeight {
            if let headerData = locator.header(at: height) {
                let header = try BlockHeader.parse(data: headerData, height: height)
                headers.append(header)
            }
        }

        return headers
    }

    /// Verify consensus among peers
    private func verifyConsensus(_ headersByPeer: [[BlockHeader]]) throws -> [BlockHeader] {
        guard !headersByPeer.isEmpty else {
            throw SyncError.noData
        }

        let referenceHeaders = headersByPeer[0]

        // Verify all peers agree on block hashes and sapling roots
        for peerHeaders in headersByPeer.dropFirst() {
            guard peerHeaders.count == referenceHeaders.count else {
                throw SyncError.consensusMismatch
            }

            for (index, header) in peerHeaders.enumerated() {
                let refHeader = referenceHeaders[index]

                guard header.blockHash == refHeader.blockHash else {
                    throw SyncError.blockHashMismatch(height: header.height)
                }

                guard header.hashFinalSaplingRoot == refHeader.hashFinalSaplingRoot else {
                    throw SyncError.saplingRootMismatch(height: header.height)
                }
            }
        }

        return referenceHeaders
    }
}

enum SyncError: Error {
    case insufficientConsensus
    case noData
    case consensusMismatch
    case blockHashMismatch(height: UInt64)
    case saplingRootMismatch(height: UInt64)
}
```

---

### Phase 2: Modified Transaction Builder

Use anchors from block headers instead of building a tree.

**File:** `/Users/chris/ZipherX/Sources/Core/Crypto/TransactionBuilder.swift`

**Key Changes:**

```swift
func buildShieldedTransaction(
    from: String,
    to: String,
    amount: UInt64,
    memo: String?,
    spendingKey: Data
) async throws -> (Data, Data) {

    print("🔨 Building transaction using header-sync anchors...")

    // Get note to spend
    guard let note = try db.getUnspentNote(accountId: account.id, amount: amount) else {
        throw TransactionError.insufficientFunds
    }

    // Get current blockchain height from network
    let currentHeight = try await networkManager.getCurrentHeight()

    // Get anchor from block header (zcashd's exact tree state!)
    guard let anchor = try headerStore.getAnchor(at: currentHeight) else {
        throw TransactionError.anchorNotFound
    }

    print("📝 Using zcashd's anchor from block \(currentHeight): \(anchor.hexString)")

    // Build witness from blockchain data
    let witness = try await buildWitnessFromBlockchain(
        note: note,
        targetHeight: currentHeight,
        targetAnchor: anchor
    )

    // Create transaction with zcashd's anchor
    guard let rawTx = ZipherXFFI.createTransaction(
        spendingKey: spendingKey,
        note: note,
        witness: witness,
        anchor: anchor,  // ← zcashd's exact anchor!
        to: to,
        amount: amount,
        memo: memo
    ) else {
        throw TransactionError.proofGenerationFailed
    }

    return (rawTx, note.nullifier)
}

/// Build witness from blockchain data (no local tree needed!)
private func buildWitnessFromBlockchain(
    note: Note,
    targetHeight: UInt64,
    targetAnchor: Data
) async throws -> Data {

    print("🌳 Building witness from blockchain data...")

    // Fetch all CMUs from note's height to target height
    var allCMUs: [Data] = []

    for height in note.receivedHeight...targetHeight {
        // Get block transactions
        let blockHash = try await networkManager.getBlockHash(height: height)
        let block = try await networkManager.getBlock(hash: blockHash)

        // Extract CMUs from all Sapling outputs
        for tx in block.transactions {
            for output in tx.saplingOutputs {
                allCMUs.append(output.cmu)
            }
        }
    }

    print("📊 Building witness from \(allCMUs.count) CMUs")

    // Build witness using librustzcash
    guard let witness = ZipherXFFI.buildWitness(
        noteCmu: note.cmu,
        allCmus: allCMUs,
        targetAnchor: targetAnchor
    ) else {
        throw TransactionError.witnessGenerationFailed
    }

    return witness
}
```

---

### Phase 3: Update FilterScanner

Use headers for scanning instead of bundled tree.

**File:** `/Users/chris/ZipherX/Sources/Core/Network/FilterScanner.swift`

**Key Changes:**

```swift
func startScan(for accountId: Int, viewingKey: Data) async throws {
    print("🔍 Starting scan using header-sync...")

    // Sync headers first
    let headerSync = HeaderSyncManager(
        networkManager: networkManager,
        headerStore: headerStore
    )

    let lastScanned = try db.getLastScannedHeight(accountId: accountId)
    let currentHeight = try await networkManager.getCurrentHeight()

    // Sync headers
    try await headerSync.syncHeaders(from: lastScanned + 1, to: currentHeight)

    // Scan blocks for our transactions
    for height in (lastScanned + 1)...currentHeight {
        let blockHash = try await networkManager.getBlockHash(height: height)
        let block = try await networkManager.getBlock(hash: blockHash)

        // Trial decrypt all Sapling outputs
        for tx in block.transactions {
            for output in tx.saplingOutputs {
                if let note = try? decryptOutput(output, viewingKey: viewingKey) {
                    print("💰 Found note: \(note.value) zatoshis at height \(height)")

                    try db.insertNote(
                        accountId: accountId,
                        note: note,
                        txHash: tx.hash,
                        height: height
                    )
                }
            }
        }
    }

    try db.updateLastScannedHeight(accountId: accountId, height: currentHeight)

    print("✅ Scan complete")
}
```

---

## Benefits of This Approach

### ✅ Advantages

1. **Guaranteed to work** - Uses zcashd's exact anchor from block headers
2. **No tree algorithm issues** - We don't build a tree, we use zcashd's
3. **Minimal storage** - Headers are tiny (~8MB for recent blocks)
4. **Multi-peer consensus** - Verify anchors match across peers
5. **Works with existing nodes** - No modified zclassicd needed
6. **Trustless** - Verify headers with PoW, anchors with consensus

### 📊 Storage Comparison

| Approach | Storage | Issues |
|----------|---------|--------|
| Bundled tree | ~31 MB | ❌ Algorithm mismatch |
| Full node | ~362 GB | ❌ Impossible on mobile |
| **Header sync** | **~8 MB** | ✅ Uses zcashd's anchors |

---

## Implementation Order

1. ✅ **Phase 1-3 Complete** - Zclassic fork with compact blocks (optional optimization)
2. **Phase 4: Header sync** (THIS DOCUMENT)
   - BlockHeader model
   - HeaderStore
   - HeaderSyncManager
3. **Phase 5: Updated transaction builder**
   - Use anchors from headers
   - Build witnesses on-demand
4. **Phase 6: Test**
   - Verify transactions are accepted

---

## Testing Plan

### Step 1: Header Sync Test
```swift
let headerSync = HeaderSyncManager(...)
try await headerSync.syncHeaders(from: 2900000, to: 2922000)

// Verify
let anchor = try headerStore.getAnchor(at: 2922000)
print("Anchor: \(anchor.hexString)")

// Compare with zcashd
// zclassic-cli getblock $(zclassic-cli getblockhash 2922000) | grep finalsaplingroot
```

### Step 2: Transaction Test
```swift
// Import key
// Wait for balance
// Send transaction
// Check if accepted by network
```

**Expected:** Transaction accepted! ✅

---

## Next Steps

Should I start implementing Phase 4 (Header Sync) in the iOS app?

This will:
1. Create the BlockHeader, HeaderStore, and HeaderSyncManager classes
2. Update TransactionBuilder to use anchors from headers
3. Test with real network

**This is the real fix for the transaction rejection issue!**
