# ZIP-307 Compact Block Implementation Plan for ZipherX

## Problem Statement

ZipherX currently fails to create valid Sapling transactions because the tree anchor computed by our Rust FFI (librustzcash) doesn't match zcashd's internal tree state, even with identical CMUs.

**Evidence:**
- Our anchor: `5aa7b916d59120ab81eda98408806b8e...`
- zcashd anchor: `4fb52b0c185a0110b5d22d7c17a9ee30b55a1ac8b8269e37b32171f98a5ae902`
- Result: All transactions rejected with `UNKNOWN(16)` error

**Root Cause:** Tree building algorithm mismatch between librustzcash and zcashd.

## Solution: Trustless Compact Blocks (Path A)

Instead of using a trusted lightwalletd server, we'll:
1. **Fork Zclassic** into ZipherX directory
2. **Add ZIP-307 compact block support** to the P2P protocol
3. **Query compact blocks from multiple peers** (maintain multi-peer consensus)
4. **Get tree state directly from zcashd** via `finalsaplingroot` in block headers
5. **Build witnesses on-demand** using compact blocks (no full tree needed)

**Benefits:**
- ✅ Trustless (multi-peer consensus, no single server)
- ✅ 80% bandwidth savings vs full blocks
- ✅ Uses zcashd's exact tree state (from block headers)
- ✅ No full node required on mobile
- ✅ Aligns with user's security principles

---

## ZIP-307 Compact Block Format

### Protobuf Definitions

```protobuf
message BlockID {
    uint64 blockHeight = 1;
    bytes blockHash = 2;
}

message CompactBlock {
    BlockID id = 1;
    repeated CompactTx vtx = 3;
}

message CompactTx {
    uint64 txIndex = 1;
    bytes txHash = 2;
    repeated CompactSpend spends = 3;
    repeated CompactOutput outputs = 4;
}

message CompactSpend {
    bytes nf = 1;  // 32-byte nullifier
}

message CompactOutput {
    bytes cmu = 1;         // 32-byte note commitment
    bytes epk = 2;         // 32-byte ephemeral public key
    bytes ciphertext = 3;  // 52 bytes (first 52 bytes of full ciphertext)
}
```

### Size Comparison

**Full Sapling Output:** ~580 bytes
- cmu: 32 bytes
- epk: 32 bytes
- ciphertext: 580 bytes (includes 512-byte memo)
- proof: ~192 bytes

**Compact Output:** 116 bytes (80% reduction)
- cmu: 32 bytes
- epk: 32 bytes
- ciphertext: 52 bytes (just the note opening data, no memo)

**Compact Spend:** 32 bytes (just nullifier)

**Annual Storage (Zclassic network):**
- Full blocks: ~730 MB
- Compact blocks: ~180 MB

---

## Implementation Phases

### Phase 1: Fork Zclassic into ZipherX

**Goal:** Create a working Zclassic fork that we can modify without affecting the original installation.

**Location:** `/Users/chris/ZipherX/zclassic-fork/`

**Steps:**

1. **Copy Zclassic source:**
```bash
cp -r /Users/chris/zclassic/zclassic /Users/chris/ZipherX/zclassic-fork
cd /Users/chris/ZipherX/zclassic-fork
```

2. **Verify it compiles:**
```bash
./autogen.sh
./configure
make -j8
```

3. **Test basic functionality:**
```bash
./src/zclassic-cli --version
./src/zclassicd --version
```

**Deliverables:**
- ✅ Working Zclassic fork in ZipherX directory
- ✅ Can compile and run independently
- ✅ Original Zclassic installation untouched

---

### Phase 2: Add Protobuf Support to Zclassic

**Goal:** Add Protocol Buffers library and generate C++ code from ZIP-307 definitions.

**Dependencies:**
- libprotobuf-dev
- protobuf-compiler

**Steps:**

1. **Create protobuf directory:**
```bash
mkdir -p /Users/chris/ZipherX/zclassic-fork/src/lightclient
cd /Users/chris/ZipherX/zclassic-fork/src/lightclient
```

2. **Create `compact_formats.proto`:**
```protobuf
syntax = "proto3";
package cash.z.wallet.sdk.rpc;

message BlockID {
    uint64 blockHeight = 1;
    bytes blockHash = 2;
}

message CompactBlock {
    BlockID id = 1;
    repeated CompactTx vtx = 3;
}

message CompactTx {
    uint64 txIndex = 1;
    bytes txHash = 2;
    repeated CompactSpend spends = 3;
    repeated CompactOutput outputs = 4;
}

message CompactSpend {
    bytes nf = 1;
}

message CompactOutput {
    bytes cmu = 1;
    bytes epk = 2;
    bytes ciphertext = 3;
}
```

3. **Generate C++ code:**
```bash
protoc --cpp_out=. compact_formats.proto
# Generates: compact_formats.pb.h and compact_formats.pb.cc
```

4. **Update Makefile.am to include protobuf files:**
```makefile
# Add to libbitcoin_server_a_SOURCES:
  lightclient/compact_formats.pb.cc \
  lightclient/compact_formats.pb.h
```

**Deliverables:**
- ✅ Protobuf definitions in Zclassic
- ✅ Generated C++ classes for CompactBlock, CompactTx, etc.
- ✅ Compiles with protobuf support

---

### Phase 3: Implement CompactBlock Builder

**Goal:** Create functions to convert full blocks to compact blocks.

**File:** `/Users/chris/ZipherX/zclassic-fork/src/lightclient/compactblock.cpp`

**Key Functions:**

```cpp
#include "lightclient/compact_formats.pb.h"
#include "primitives/block.h"
#include "primitives/transaction.h"

namespace lightclient {

// Convert full block to compact block
CompactBlock BlockToCompactBlock(const CBlock& block, int height) {
    CompactBlock compactBlock;

    // Set block ID
    BlockID* blockId = compactBlock.mutable_id();
    blockId->set_blockheight(height);
    blockId->set_blockhash(block.GetHash().begin(), 32);

    // Convert each transaction
    for (size_t txIndex = 0; txIndex < block.vtx.size(); txIndex++) {
        const CTransaction& tx = block.vtx[txIndex];

        // Skip transactions with no Sapling data
        if (tx.vShieldedSpend.empty() && tx.vShieldedOutput.empty()) {
            continue;
        }

        CompactTx* compactTx = compactBlock.add_vtx();
        compactTx->set_txindex(txIndex);
        compactTx->set_txhash(tx.GetHash().begin(), 32);

        // Add compact spends (just nullifiers)
        for (const auto& spend : tx.vShieldedSpend) {
            CompactSpend* compactSpend = compactTx->add_spends();
            compactSpend->set_nf(spend.nullifier.begin(), 32);
        }

        // Add compact outputs (cmu + epk + first 52 bytes of ciphertext)
        for (const auto& output : tx.vShieldedOutput) {
            CompactOutput* compactOutput = compactTx->add_outputs();
            compactOutput->set_cmu(output.cmu.begin(), 32);
            compactOutput->set_epk(output.ephemeralKey.begin(), 32);
            compactOutput->set_ciphertext(output.ciphertext.begin(), 52);
        }
    }

    return compactBlock;
}

} // namespace lightclient
```

**Deliverables:**
- ✅ `BlockToCompactBlock()` function
- ✅ Properly extracts nullifiers, CMUs, epk, and ciphertext
- ✅ Unit tests for compact block conversion

---

### Phase 4: Add P2P Message for Compact Blocks

**Goal:** Add `getcompactblock` P2P message to Zclassic protocol.

**Files to Modify:**

#### 4.1. Add message type to `protocol.h`

```cpp
// File: /Users/chris/ZipherX/zclassic-fork/src/protocol.h

enum {
    MSG_TX = 1,
    MSG_BLOCK,
    MSG_FILTERED_BLOCK,
    MSG_COMPACT_BLOCK,  // ADD THIS
};
```

#### 4.2. Add message handler in `main.cpp`

```cpp
// File: /Users/chris/ZipherX/zclassic-fork/src/main.cpp

else if (strCommand == "getcompactblock")
{
    uint256 blockHash;
    vRecv >> blockHash;

    LogPrint("net", "getcompactblock %s from peer=%d\n",
             blockHash.ToString(), pfrom->id);

    // Find the block
    BlockMap::iterator mi = mapBlockIndex.find(blockHash);
    if (mi == mapBlockIndex.end() || !mi->second) {
        LogPrint("net", "block not found\n");
        return true;
    }

    CBlockIndex* pindex = mi->second;

    // Load the block
    CBlock block;
    if (!ReadBlockFromDisk(block, pindex, Params().GetConsensus())) {
        LogPrint("net", "failed to read block from disk\n");
        return error("getcompactblock: ReadBlockFromDisk failed");
    }

    // Convert to compact block
    lightclient::CompactBlock compactBlock =
        lightclient::BlockToCompactBlock(block, pindex->nHeight);

    // Serialize and send
    std::string serialized;
    compactBlock.SerializeToString(&serialized);

    pfrom->PushMessage("compactblock", serialized);

    return true;
}

else if (strCommand == "compactblock")
{
    std::string serialized;
    vRecv >> serialized;

    lightclient::CompactBlock compactBlock;
    if (!compactBlock.ParseFromString(serialized)) {
        return error("Failed to parse CompactBlock");
    }

    LogPrint("net", "Received compact block %d with %d transactions\n",
             compactBlock.id().blockheight(), compactBlock.vtx_size());

    // Store or process compact block
    // (Implementation depends on how we want to handle it)

    return true;
}
```

**Deliverables:**
- ✅ `getcompactblock` message handler
- ✅ `compactblock` response handler
- ✅ Proper serialization/deserialization
- ✅ Works with existing P2P infrastructure

---

### Phase 5: Modify ZipherX iOS App

**Goal:** Update the iOS app to query compact blocks from multiple peers and use zcashd's tree state.

#### 5.1. Add Swift Protobuf Support

**File:** `Podfile` or Package.swift

```swift
dependencies: [
    .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.25.0")
]
```

#### 5.2. Generate Swift protobuf code

```bash
cd /Users/chris/ZipherX
protoc --swift_out=Sources/Core/Network/ \
       zclassic-fork/src/lightclient/compact_formats.proto
```

#### 5.3. Create CompactBlockManager

**File:** `/Users/chris/ZipherX/Sources/Core/Network/CompactBlockManager.swift`

```swift
import Foundation

class CompactBlockManager {
    private let networkManager: NetworkManager
    private let minPeers = 8
    private let consensusThreshold = 6

    /// Query compact blocks from multiple peers with consensus
    func fetchCompactBlocks(from startHeight: UInt64, to endHeight: UInt64) async throws -> [CompactBlock] {

        // Query from multiple peers in parallel
        let peers = try await networkManager.getConnectedPeers(minimum: minPeers)

        var compactBlocksByPeer: [[CompactBlock]] = []

        await withTaskGroup(of: (Int, [CompactBlock]?).self) { group in
            for (index, peer) in peers.enumerated() {
                group.addTask {
                    do {
                        let blocks = try await self.fetchFromPeer(
                            peer,
                            from: startHeight,
                            to: endHeight
                        )
                        return (index, blocks)
                    } catch {
                        print("❌ Failed to fetch from peer \(index): \(error)")
                        return (index, nil)
                    }
                }
            }

            for await (_, blocks) in group {
                if let blocks = blocks {
                    compactBlocksByPeer.append(blocks)
                }
            }
        }

        // Require consensus among peers
        guard compactBlocksByPeer.count >= consensusThreshold else {
            throw NetworkError.insufficientConsensus
        }

        // Verify all peers agree on block hashes
        let consensusBlocks = try verifyConsensus(compactBlocksByPeer)

        print("✅ Fetched \(consensusBlocks.count) compact blocks with consensus")
        return consensusBlocks
    }

    /// Fetch compact blocks from a single peer
    private func fetchFromPeer(_ peer: Peer, from: UInt64, to: UInt64) async throws -> [CompactBlock] {
        var blocks: [CompactBlock] = []

        for height in from...to {
            // Get block hash for height
            let blockHash = try await peer.getBlockHash(height: height)

            // Request compact block
            let request = GetCompactBlockMessage(blockHash: blockHash)
            try await peer.send(request)

            // Receive compact block
            let response = try await peer.receive() as CompactBlockMessage
            blocks.append(response.block)
        }

        return blocks
    }

    /// Verify consensus among peers
    private func verifyConsensus(_ blocksByPeer: [[CompactBlock]]) throws -> [CompactBlock] {
        guard !blocksByPeer.isEmpty else {
            throw NetworkError.noData
        }

        let referenceBlocks = blocksByPeer[0]

        // Verify all peers agree on block hashes
        for peerBlocks in blocksByPeer.dropFirst() {
            guard peerBlocks.count == referenceBlocks.count else {
                throw NetworkError.consensusMismatch
            }

            for (index, block) in peerBlocks.enumerated() {
                let refBlock = referenceBlocks[index]
                guard block.id.blockHash == refBlock.id.blockHash else {
                    throw NetworkError.blockHashMismatch(
                        height: Int(block.id.blockHeight)
                    )
                }
            }
        }

        return referenceBlocks
    }
}
```

#### 5.4. Update FilterScanner to use CompactBlocks

**File:** `/Users/chris/ZipherX/Sources/Core/Network/FilterScanner.swift`

**Changes:**

```swift
// OLD: Scan using bundled tree + incremental scanning
// NEW: Scan using compact blocks + zcashd tree state

func startScan(for accountId: Int, viewingKey: Data) async throws {
    print("🔍 Starting scan with compact blocks...")

    let compactBlockManager = CompactBlockManager()

    // Get last scanned height
    let lastScanned = try db.getLastScannedHeight(accountId: accountId)
    let currentHeight = try await networkManager.getCurrentHeight()

    // Fetch compact blocks with multi-peer consensus
    let compactBlocks = try await compactBlockManager.fetchCompactBlocks(
        from: lastScanned + 1,
        to: currentHeight
    )

    print("📦 Received \(compactBlocks.count) compact blocks")

    // Trial decrypt outputs
    for compactBlock in compactBlocks {
        for compactTx in compactBlock.vtx {
            for compactOutput in compactTx.outputs {
                // Try to decrypt with our viewing key
                if let note = try? decryptCompactOutput(
                    compactOutput,
                    viewingKey: viewingKey
                ) {
                    print("💰 Found note: \(note.value) zatoshis")

                    // Save note to database
                    try db.insertNote(
                        accountId: accountId,
                        note: note,
                        txHash: compactTx.txHash,
                        height: compactBlock.id.blockHeight
                    )
                }
            }
        }
    }

    // Update last scanned height
    try db.updateLastScannedHeight(accountId: accountId, height: currentHeight)

    print("✅ Scan complete")
}

// Trial decrypt a compact output
private func decryptCompactOutput(
    _ output: CompactOutput,
    viewingKey: Data
) throws -> Note? {
    // Use librustzcash to try decrypting
    return ZipherXFFI.tryDecryptCompactOutput(
        cmu: output.cmu,
        epk: output.epk,
        ciphertext: output.ciphertext,
        viewingKey: viewingKey
    )
}
```

#### 5.5. Build Witnesses On-Demand

**Key Insight:** We don't need to maintain a full tree anymore. When spending, we can:

1. **Get anchor from block header** (`finalsaplingroot` field)
2. **Build witness path on-demand** using compact blocks
3. **This matches zcashd's tree state EXACTLY**

**File:** `/Users/chris/ZipherX/Sources/Core/Crypto/TransactionBuilder.swift`

```swift
func buildShieldedTransaction(
    from: String,
    to: String,
    amount: UInt64,
    memo: String?,
    spendingKey: Data
) async throws -> (Data, Data) {

    print("🔨 Building transaction using on-demand witnesses...")

    // Get note to spend
    guard let note = try db.getUnspentNote(accountId: account.id, amount: amount) else {
        throw TransactionError.insufficientFunds
    }

    // Get block header for note's height
    let blockHeader = try await networkManager.getBlockHeader(height: note.receivedHeight)

    // Use zcashd's anchor from block header
    let anchor = blockHeader.finalsaplingroot
    print("📝 Using zcashd's anchor: \(anchor.hexString)")

    // Build witness path from compact blocks
    let witness = try await buildWitnessFromCompactBlocks(
        note: note,
        targetAnchor: anchor
    )

    // Create transaction
    guard let rawTx = ZipherXFFI.createTransaction(
        spendingKey: spendingKey,
        note: note,
        witness: witness,
        anchor: anchor,
        to: to,
        amount: amount,
        memo: memo
    ) else {
        throw TransactionError.proofGenerationFailed
    }

    return (rawTx, note.nullifier)
}

/// Build witness from compact blocks
private func buildWitnessFromCompactBlocks(
    note: Note,
    targetAnchor: Data
) async throws -> Data {

    // Fetch compact blocks from note's height to current
    let compactBlocks = try await compactBlockManager.fetchCompactBlocks(
        from: note.receivedHeight,
        to: currentHeight
    )

    // Extract all CMUs from compact blocks
    var cmus: [Data] = []
    for block in compactBlocks {
        for tx in block.vtx {
            for output in tx.outputs {
                cmus.append(output.cmu)
            }
        }
    }

    // Build witness using librustzcash
    guard let witness = ZipherXFFI.buildWitness(
        noteCmu: note.cmu,
        allCmus: cmus,
        targetAnchor: targetAnchor
    ) else {
        throw TransactionError.witnessGenerationFailed
    }

    return witness
}
```

**Deliverables:**
- ✅ CompactBlockManager with multi-peer consensus
- ✅ Updated FilterScanner using compact blocks
- ✅ On-demand witness building from compact blocks
- ✅ Uses zcashd's anchor from block headers (EXACT match)

---

### Phase 6: Test and Verify

#### 6.1. Compile Modified Zclassic

```bash
cd /Users/chris/ZipherX/zclassic-fork
./autogen.sh
./configure
make -j8
```

#### 6.2. Run Modified Zclassic Node

```bash
./src/zclassicd -daemon
```

#### 6.3. Test Compact Block Messages

```bash
# Test getcompactblock message
./src/zclassic-cli getblock <block_hash> | python3 test_compact.py
```

#### 6.4. Test ZipherX App

1. Launch app with modified code
2. Import test key
3. Scan blockchain using compact blocks
4. Verify balance matches
5. Send test transaction
6. **Verify transaction is ACCEPTED by zcashd**

#### 6.5. Verify Anchor Match

```bash
# Extract anchor from transaction
python3 Tools/parse_tx_anchor.py <raw_tx_hex>

# Compare with zcashd's anchor at current height
python3 Tools/verify_anchor.py <current_height>

# They should MATCH now!
```

**Deliverables:**
- ✅ Modified Zclassic node responds to `getcompactblock`
- ✅ ZipherX app successfully scans with compact blocks
- ✅ Transaction builds with correct anchor
- ✅ Transaction ACCEPTED by zcashd network
- ✅ Anchor verification passes

---

## Security Considerations

### Multi-Peer Consensus Requirements

- **Minimum peers:** 8
- **Consensus threshold:** 6 (75%)
- **Block hash verification:** All peers must agree on block hashes
- **Anchor verification:** Use anchor from block header (signed by miners)

### Attack Vectors

1. **Sybil Attack:** Multiple malicious peers
   - **Mitigation:** Require 75% consensus, rotate peers

2. **Eclipse Attack:** Isolated from honest peers
   - **Mitigation:** Connect to diverse IP ranges, seed nodes

3. **Block withholding:** Peers hide relevant transactions
   - **Mitigation:** Query multiple peers, verify against headers

4. **Anchor manipulation:** Peers provide wrong anchors
   - **Mitigation:** Anchor comes from block header (POW-secured), not from peer responses

### Privacy Considerations

- Trial decryption happens **locally** (peer doesn't know which notes are ours)
- Query compact blocks for **all transactions** (no selective requests)
- No correlation between queries and addresses

---

## Comparison with Original Approach

| Aspect | Bundled Tree + Scan | Compact Blocks (This Plan) |
|--------|---------------------|----------------------------|
| **Tree maintenance** | Build full tree locally | Use zcashd's tree state |
| **Anchor accuracy** | ❌ Mismatch with zcashd | ✅ Exact match (from headers) |
| **Bandwidth** | ~730 MB/year | ~180 MB/year (80% savings) |
| **Trust model** | Trustless | Trustless (multi-peer) |
| **Transaction success** | ❌ Rejected (wrong anchor) | ✅ Accepted (correct anchor) |
| **Complexity** | High (tree algorithm) | Medium (P2P modification) |
| **Mobile feasibility** | Difficult | Practical |

---

## Next Steps

You need to:

1. **Review this plan** - Make sure it aligns with your security requirements
2. **Copy Zclassic source** - Create the fork in ZipherX directory
3. **Set up development environment** - Install protobuf compiler, dependencies
4. **Begin Phase 1** - Get the fork compiling

**Command to start:**
```bash
# Copy Zclassic to ZipherX
cp -r /Users/chris/zclassic/zclassic /Users/chris/ZipherX/zclassic-fork

# Verify it compiles
cd /Users/chris/ZipherX/zclassic-fork
./autogen.sh
./configure
make -j8
```

Let me know when you're ready to proceed, and I'll guide you through each phase step by step!

---

## References

- [ZIP-307: Light Client Protocol for Payment Detection](https://zips.z.cash/zip-0307)
- [Zcash Protocol Specification](https://zips.z.cash/protocol/protocol.pdf)
- [Protocol Buffers Documentation](https://developers.google.com/protocol-buffers)
- [Zcash lightwalletd](https://github.com/zcash/lightwalletd)
- [BIP-158: Compact Block Filters](https://github.com/bitcoin/bips/blob/master/bip-0158.mediawiki)

---

**Document Version:** 1.0
**Created:** November 25, 2025
**Author:** Claude (ZipherX Development Assistant)
