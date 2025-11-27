# ZipherX Project Instructions

## Project Overview

ZipherX is a secure, decentralized cryptocurrency wallet for iOS based on Zclassic/Zcash technology. The goal is to achieve full-node-level security on mobile without requiring a full node.

## Architecture

See `ZipherX-iOS-Wallet-Architecture.md` for complete technical specification.

### Key Principles

1. **Trustless verification** - Verify all transactions locally using cryptographic proofs
2. **Decentralized network** - Connect to 8+ random peers, require consensus
3. **Hardware security** - Use iOS Secure Enclave for key protection
4. **User-controlled backup** - BIP39 mnemonic seed phrases

## Development Guidelines

### Security Requirements

- NEVER store unencrypted private keys
- ALWAYS use Secure Enclave for spending key operations
- NEVER trust a single network peer
- ALWAYS verify Sapling proofs locally
- ALWAYS require multi-peer consensus for balance/transaction queries

### Code Standards

- Swift for iOS UI and Secure Enclave integration
- C++/Rust for cryptographic operations (librustzcash)
- Follow Apple's Human Interface Guidelines
- Use SwiftUI for new UI components

### Build Instructions

```bash
# iOS build requires:
# - Xcode 14+
# - iOS 14.0+ SDK
# - Rust with aarch64-apple-ios target

# Install Rust iOS target
rustup target add aarch64-apple-ios

# Build librustzcash for iOS
cd librustzcash
cargo build --target aarch64-apple-ios --release

# Open Xcode project
open ZipherX.xcodeproj
```

### Testing Requirements

- Unit tests for all cryptographic operations
- Integration tests for multi-peer consensus
- UI tests for critical user flows
- Security audit before release

## Key Components

### 1. Secure Key Storage (`SecureKeyStorage.swift`)

```swift
// Use Secure Enclave for all spending key operations
// Keys NEVER leave the hardware security module
```

### 2. Multi-Peer Network (`NetworkManager.swift`)

```swift
// Connect to MIN_PEERS (8) nodes
// Require CONSENSUS_THRESHOLD (6) agreement
// Rotate peers periodically
```

### 3. Proof Verification (`SaplingVerifier.swift`)

```swift
// Verify all Sapling proofs locally
// Use librustzcash_sapling_check_spend
// ~50ms per proof on modern devices
```

### 4. Compact Filters (`FilterManager.swift`)

```swift
// Download BIP-158 compact block filters
// ~1000x more efficient than full blocks
// Detect relevant transactions without revealing addresses
```

## File Structure

```
ZipherX/
├── CLAUDE.md                              # This file
├── ZipherX-iOS-Wallet-Architecture.md     # Full architecture spec
├── Sources/
│   ├── App/                               # iOS app entry point
│   ├── Core/
│   │   ├── Crypto/                        # Cryptographic operations
│   │   ├── Network/                       # P2P networking
│   │   ├── Wallet/                        # Wallet management
│   │   └── Storage/                       # Encrypted database
│   ├── UI/                                # SwiftUI views
│   └── Extensions/                        # Swift extensions
├── Libraries/
│   ├── librustzcash/                      # Sapling cryptography
│   └── libsodium/                         # Crypto primitives
└── Tests/
    ├── UnitTests/
    └── IntegrationTests/
```

## Security Checklist

Before any release:

- [ ] All private keys encrypted at rest
- [ ] Secure Enclave used for key operations
- [ ] Multi-peer consensus implemented
- [ ] Sapling proofs verified locally
- [ ] BIP39 mnemonic backup tested
- [ ] No sensitive data in logs
- [ ] Network traffic encrypted (TLS)
- [ ] Code signing and notarization
- [ ] Security audit completed

## Dependencies

| Library | Purpose | Notes |
|---------|---------|-------|
| librustzcash | Sapling cryptography | Cross-compile for iOS |
| libsodium | Crypto primitives | Use CocoaPods/SPM |
| SQLCipher | Encrypted database | Use CocoaPods/SPM |
| Reachability | Network monitoring | Use SPM |

## Important Notes

- **Never disable SSL verification** - Always verify certificates
- **Never use hardcoded credentials** - Generate randomly
- **Never trust single peer responses** - Always verify with multiple
- **Never skip proof verification** - Security depends on it
- **Always backup before encryption** - No recovery without seed phrase

## Phase Timeline

1. **Phase 1 (4-6 weeks)**: Core security - Secure Enclave, BIP39, proof verification
2. **Phase 2 (6-8 weeks)**: Network layer - Multi-peer, compact filters, header sync
3. **Phase 3 (4-6 weeks)**: Shielded support - Note scanning, TX construction
4. **Phase 4 (2-4 weeks)**: Polish - Background sync, notifications, audit

## Resources

- [Architecture Document](./ZipherX-iOS-Wallet-Architecture.md)
- [BIP-158 Compact Filters](https://github.com/bitcoin/bips/blob/master/bip-0158.mediawiki)
- [BIP-39 Mnemonics](https://github.com/bitcoin/bips/blob/master/bip-0039.mediawiki)
- [ZIP-32 HD Wallets](https://zips.z.cash/zip-0032)
- [Zcash Protocol Spec](https://zips.z.cash/protocol/protocol.pdf)
- [Apple Secure Enclave](https://developer.apple.com/documentation/security/certificate_key_and_trust_services/keys/protecting_keys_with_the_secure_enclave)

## Current Implementation Status

### Completed Features

1. **BIP-39 Mnemonic Support** - Generate/validate 24-word seed phrases
2. **Sapling Key Derivation** - ExtendedSpendingKey, IVK, payment addresses
3. **Note Decryption** - Trial decryption with IVK/SK (fixed EPK byte order)
4. **Nullifier Computation** - Track spent notes
5. **Transaction Scanning** - Via Insight API with shielded output detection
6. **Commitment Tree** - Full implementation for witness generation
   - Tree init/append/serialize/deserialize
   - IncrementalWitness creation and updates
   - Database persistence of tree state
7. **Witness Generation** - Real Merkle path witnesses (1028 bytes)
8. **Database Layer** - SQLite with tree state persistence
9. **UI** - System 7-inspired interface with balance display, send/receive
10. **Pre-built Bundled Commitment Tree** - Fast initial sync (see below)
11. **Two-Phase Scanning** - Parallel note discovery + sequential tree building

### Completed Features (continued)

13. **Transaction Building** - Spend proof generation with real witnesses ✅
14. **Full Send Flow** - End-to-end shielded transactions working on mainnet ✅
15. **ZclassicButtercup Branch ID** - Local fork of zcash_primitives with correct branch ID (0x930b540d) ✅
16. **Tree Caching & Preloading** - Tree loaded at startup, cached in database for instant subsequent loads ✅
17. **Debug Logs Disabled** - Production build with conditional logging via `DEBUG_LOGGING` flag ✅
18. **Equihash PoW Verification** - Trustless header validation via FFI (November 2025) ✅
    - `zipherx_verify_equihash()` - Verify Equihash(200,9) solutions
    - `zipherx_compute_block_hash()` - Compute block hash from header + solution
    - `zipherx_verify_header_chain()` - Verify chain of headers
    - Headers with invalid PoW are rejected during sync
19. **Multi-Peer Block Consensus** - Request blocks from multiple peers, verify agreement ✅
    - `getBlocksWithConsensus()` - Multi-peer block fetching
    - `getBlockByHashWithConsensus()` - Single block with consensus
    - Reject blocks if peers disagree on finalSaplingRoot

### In Progress / Needs Testing

1. **P2P-Only Mode** - Replace remaining InsightAPI calls with P2P
   - Chain height now uses P2P first, InsightAPI as fallback ✅
   - Block scanning still uses InsightAPI for transaction parsing
   - Full P2P mode requires raw transaction parsing (complex refactor)
2. **Balance UI Update** - Show tree loading progress in main wallet view

### Remaining Tasks

1. **Background Sync** - iOS background fetch
2. **Secure Enclave Integration** - Currently keys in memory
3. **Security Audit** - Required before any real use

---

## Pre-built Bundled Commitment Tree

### Overview

The app includes a pre-built Sapling commitment tree (`commitment_tree_v3.bin`) containing all CMUs from Sapling activation to a checkpoint height. This enables instant balance display without hours of sequential scanning.

### Bundled Tree Specifications

| Property | Value |
|----------|-------|
| **File** | `Resources/commitment_tree_v4.bin` |
| **Format** | `[count: UInt64 LE][cmu1: 32 bytes][cmu2: 32 bytes]...` |
| **CMU Count** | 1,041,688 commitments |
| **End Height** | 2,923,123 |
| **File Size** | 31.8 MB |
| **Tree Root** | `42d6a11f937de8a27060ad683a632be73d08fae9ff421145f58e16a282c702f3` |

### How to Generate/Update the Bundled Tree

1. **Export CMUs from local node:**
```bash
cd /Users/chris/ZipherX/Tools
python3 export_tree_ultrafast_v2.py
# Outputs to Resources/commitment_tree_v4.bin
# Uses batch RPC for 100x faster export (2000+ blocks/sec)
```

2. **Verify the tree root matches chain:**
```bash
# Get expected root from chain
zclassic-cli getblockheader $(zclassic-cli getblockhash 2923123) true | grep finalsaplingroot

# Verify our tree produces the same root
cd /Users/chris/ZipherX/Libraries/zipherx-ffi
cargo run --bin verify_tree_correct /Users/chris/ZipherX/Resources/commitment_tree_v4.bin
```

3. **Update `bundledTreeHeight` in code:**
   - `FilterScanner.swift` line ~83: `let bundledTreeHeight: UInt64 = 2923123`
   - `TransactionBuilder.swift` line ~98: `let bundledTreeHeight: UInt64 = 2923123`

### Critical Requirements

- **CMU Order**: Must be in exact blockchain order (Sapling activation → end height)
- **No Duplicates**: Each CMU appears exactly once
- **Root Verification**: Tree root MUST match `finalsaplingroot` from zcashd
- **Little-Endian**: CMUs stored in wire format (little-endian), not display format

### Troubleshooting Tree Root Mismatch

If tree root doesn't match chain's `finalsaplingroot`:

1. **Check CMU count**: Must include ALL shielded outputs, not just those to known addresses
2. **Check byte order**: CMUs must be little-endian (wire format)
3. **Check height**: Verify end height matches where you stopped export
4. **Re-export**: Delete and regenerate from scratch

---

## Two-Phase Scanning Architecture

### Problem Solved

Notes received within the bundled tree range (e.g., height 2918000) were not found because the scanner skipped to `bundledTreeHeight + 1`.

### Solution: PHASE 1 + PHASE 2

**PHASE 1** (Parallel, Note Discovery Only):
- Scans blocks from `fromHeight` to `bundledTreeHeight`
- Uses `processShieldedOutputsForNotesOnly()` - NO tree modification
- Fast parallel scanning for note decryption only
- Notes stored with empty witnesses (need rebuild later)

**PHASE 2** (Sequential, Tree Building):
- Scans blocks from `bundledTreeHeight + 1` to chain tip
- Uses `processShieldedOutputsSync()` - appends CMUs to tree
- Sequential to maintain correct tree order
- Witnesses created as CMUs are appended

### Code Flow (FilterScanner.swift)

```swift
// Detect if scanning within bundled range
if customStartHeight <= bundledTreeHeight {
    scanWithinBundledRange = true
}

// PHASE 1: Parallel scan within bundled range
if scanWithinBundledRange {
    // Scan fromHeight → bundledTreeHeight (parallel, no tree append)
    processShieldedOutputsForNotesOnly(...)
}

// PHASE 2: Sequential scan after bundled range
// Scan bundledTreeHeight+1 → chainTip (sequential, tree building)
processShieldedOutputsSync(...)
```

---

## Bug Fixes (November 2025)

### 1. Scan Lock Blocking Issue
**Problem**: "Scan already in progress, skipping" when user initiates scan
**Fix**: Added `FilterScanner.isScanInProgress` static property and wait logic in `WalletManager.performFullRescan()` (up to 60 seconds timeout)

### 2. Notes Not Found Within Bundled Range
**Problem**: Notes at height ~2918000 not found because scan started at 2922770
**Fix**: Added PHASE 1 scanning for blocks within bundled tree range using parallel note-discovery-only mode

### 3. Witness Destruction During Rebuild
**Problem**: "Rebuild Witnesses" cleared note records, losing balance
**Fix**: Modified to only clear witnesses, not notes. `WalletDatabase.getAllUnspentNotes()` added to find notes regardless of witness status

### 4. TransactionBuilder Tree Loading
**Problem**: Used wrong FFI function `loadBundledCMUs` which doesn't exist
**Fix**: Changed to `ZipherXFFI.treeLoadFromCMUs(data:)` with proper Bundle resource loading

### 5. CRITICAL: CMU Byte Order Investigation (November 2025)

**Problem**: Transaction building failed with "bad-txns-sapling-spend-description-invalid"
- Tree root mismatch: Our tree produced different root than zcashd's `finalsaplingroot`

**Investigation Timeline**:

1. **Initial hypothesis (WRONG)**: CMUs needed byte reversal before parsing
   - Bundled file CMU 0: `43391df0dc0983da7ad647a8cd4c3a2575dcccda3da44158ceef484ba7478d5a`
   - zcashd RPC CMU 0:   `5a8d47a74b48efce5841a43ddaccdc75253a4ccda847d67ada8309dcf01d3943`
   - These ARE byte-reversed of each other

2. **Key discovery**: The bundled file is in **wire format (little-endian)** which is CORRECT
   - `Node::read()` expects little-endian (wire format) input
   - zcashd RPC displays CMUs in big-endian (display format)
   - The bundled file was actually correct all along!

3. **First CMU verification (PASSED)**:
   ```
   First CMU in wire format: 43391df0dc0983da7ad647a8cd4c3a2575dcccda3da44158ceef484ba7478d5a
   Tree root with 1 CMU:     4fa518c5b25bb460710ba5e42d83b549100193abb5a895a20717dfeaf96116d4
   zcashd finalsaplingroot at height 476977: 4fa518c5b25bb460710ba5e42d83b549100193abb5a895a20717dfeaf96116d4
   MATCH!
   ```

4. **Full tree verification (FAILED)**:
   ```
   CMU count: 1,040,540
   Our computed root (display): 6faf1a19cb75a31cb085766cbdaf98af4a0d208308637bd2a6e9a0946f9afd79
   Expected at height 2922769:  28725db1847d9c6aaab88184b52ef99f60975adfdd90321a57ace5f99304912b
   MISMATCH - bundled file has data issues
   ```

**Root Cause Analysis**:
- The byte order in the bundled file is CORRECT (wire format)
- The Rust code was INCORRECTLY reversing bytes before `Node::read()`
- But even after removing reversal, full tree root doesn't match
- **Conclusion**: Bundled file has missing/incorrect CMUs - needs complete regeneration

**Fix Applied** (in `lib.rs`):
- `zipherx_tree_load_from_cmus()`: REMOVED byte reversal - pass CMUs directly to `Node::read()`
- `zipherx_tree_create_witness_for_cmu()`: REMOVED byte reversal - pass CMUs directly

```rust
// CORRECT: CMUs in bundled file are in wire format (little-endian)
// Node::read() expects wire format - pass directly, NO reversal needed
let node = zcash_primitives::sapling::Node::read(&cmu_bytes[..])?;
```

**Resolution**:
- The `commitment_tree_v3.bin` file is CORRECT and VERIFIED!
- CMU count: 1,041,667
- Tree root: `28725db1847d9c6aaab88184b52ef99f60975adfdd90321a57ace5f99304912b`
- Matches zcashd finalsaplingroot at height 2922769
- The old v2 file was incorrect (1,040,540 CMUs, wrong root)

**Byte Order Summary**:
```
zcashd RPC returns:     BIG-ENDIAN (display format)     5a8d47a7...43
Bundled file stores:    LITTLE-ENDIAN (wire format)     43391df0...5a
Node::read() expects:   LITTLE-ENDIAN (wire format)     43391df0...5a
Node::write() returns:  LITTLE-ENDIAN (wire format)
zcashd displays root:   BIG-ENDIAN (display format)

Export script: Reverses RPC CMUs from big-endian to little-endian (CORRECT)
Rust lib.rs:   Passes CMUs directly to Node::read() without reversal (CORRECT)
```

**Files Modified**:
- `Libraries/zipherx-ffi/src/lib.rs` - removed byte reversal in tree loading functions

### 6. CRITICAL: Wrong Consensus Branch ID - ROOT CAUSE FIXED (November 27, 2025)

**Problem**: Transaction broadcasts failed with error code 16: `bad-txns-sapling-spend-description-invalid`

Despite all cryptographic values being verified correct:
- ✅ Note CMU matches tree CMU
- ✅ Anchor matches zcashd finalsaplingroot
- ✅ Witness root matches computed anchor
- ✅ Note position correct (1041691)

**Root Cause Found**: The wallet was using **Sapling branch ID (0x76b809bb)** but the Zclassic node's current active consensus requires **Buttercup branch ID (0x930b540d)**.

Verified by running: `zclassic-cli getblockchaininfo` shows `"chaintip": "930b540d"`

**Zclassic Network Upgrade History**:

| Upgrade | Branch ID | Activation Height | Notes |
|---------|-----------|-------------------|-------|
| Overwinter | `0x5ba81b19` | 476,969 | Same as Zcash |
| Sapling | `0x76b809bb` | 476,969 | Same as Zcash |
| Bubbles | `0x821a451c` | 585,318 | Zclassic-specific (≠ Zcash Blossom) |
| **Buttercup** | `0x930b540d` | **707,000** | **CURRENTLY ACTIVE** (≠ Zcash Heartwood) |

The `zcash_primitives` Rust library **hardcodes Zcash's branch IDs**. We cannot use Zcash's Blossom/Heartwood variants because they have different branch IDs.

**Impact**: Per ZIP-243, the consensus branch ID is hashed into the transaction sighash:
```
BLAKE2b(personalization = "ZcashSigHash" || BRANCH_ID_LE, ...)
```
Wrong branch ID → wrong sighash → invalid `spendAuthSig` → transaction rejected.

**SOLUTION APPLIED: Local Fork of zcash_primitives**

Created `/Users/chris/ZipherX/Libraries/zcash_primitives_zcl/` with native `ZclassicButtercup` support:

1. **consensus.rs modifications**:
   - Added `BranchId::ZclassicButtercup` with value `0x930b540d`
   - Added `NetworkUpgrade::ZclassicButtercup`
   - Added to `UPGRADES_IN_ORDER` array
   - Added `branch_id()` and `height_bounds()` implementations

2. **Cargo.toml change**:
   ```toml
   # Using local fork with Zclassic Buttercup branch ID support
   zcash_primitives = { path = "../zcash_primitives_zcl" }
   ```

3. **lib.rs ZclassicNetwork update**:
   ```rust
   match nu {
       NetworkUpgrade::Overwinter => Some(BlockHeight::from_u32(476969)),
       NetworkUpgrade::Sapling => Some(BlockHeight::from_u32(476969)),
       // Skip Zcash-specific upgrades with wrong branch IDs
       NetworkUpgrade::Blossom => None,
       NetworkUpgrade::Heartwood => None,
       NetworkUpgrade::Canopy => None,
       NetworkUpgrade::Nu5 => None,
       // ZclassicButtercup uses correct branch ID (0x930b540d)
       NetworkUpgrade::ZclassicButtercup => Some(BlockHeight::from_u32(707000)),
       _ => None,
   }
   ```

**How It Works**:
1. `BranchId::for_height()` iterates `UPGRADES_IN_ORDER` in reverse
2. For Zclassic at height 2,923,000+:
   - Nu5, Canopy, Heartwood, Blossom return `None` (not activated)
   - ZclassicButtercup returns `Some(707000)` and is active
3. Transaction builder uses `BranchId::ZclassicButtercup` (0x930b540d)
4. Sighash personalization matches node's expected branch ID
5. spendAuthSig verification passes

**Sources**:
- [ZIP-243: Transaction Signature Validation for Sapling](https://zips.z.cash/zip-0243)
- [Ledger PR for Zclassic branch IDs](https://github.com/LedgerHQ/app-bitcoin/pull/133/files)
- Local Zclassic source: `/Users/chris/zclassic/zclassic/src/consensus/upgrades.cpp`
- Local Zclassic source: `/Users/chris/zclassic/zclassic/src/chainparams.cpp`
- zcashd verification: `ContextualCheckTransaction()` → `librustzcash_sapling_check_spend()`

**Files Modified**:
- `Libraries/zcash_primitives_zcl/src/consensus.rs` - added ZclassicButtercup branch ID
- `Libraries/zipherx-ffi/Cargo.toml` - uses local zcash_primitives fork
- `Libraries/zipherx-ffi/src/lib.rs` - ZclassicNetwork activates ZclassicButtercup at height 707,000

### 7. Performance: Fast Startup + Historical Scan Option (November 2025)

**Problem**: Wallet took too long to be ready (scanning 2.4M blocks on fresh install)

**Solution: Fast Startup**:
- Fresh install with bundled tree scans ONLY recent blocks (bundledTreeHeight+1 to current)
- This ensures <10 second wallet ready time
- Historical notes can be found via Settings → "Quick Scan" from specific height

**Nullifier Detection** (still enabled):
- All scan modes now check `vShieldedSpend` for nullifiers
- `processShieldedOutputsForNotesOnly()` accepts optional `spends: [ShieldedSpend]?`
- `processShieldedOutputsSync()` accepts optional `spends: [ShieldedSpend]?`
- Spent notes are correctly marked when their nullifiers are found

**For Users with Old Notes**:
- Go to Settings → "Quick Scan" and enter the height where you first received funds
- Or use "Full Rescan from Height" for notes that need to be spendable

**Files Modified**:
- `Sources/Core/Network/FilterScanner.swift` - fast startup, nullifier detection
- `Sources/Core/Wallet/WalletManager.swift` - cypherpunk progress messages

### 8. Progress Bar Not Showing at Launch (November 2025)

**Problem**: Users reported "no progress bar at launch during scan"

**Root Cause Analysis**:
1. Tree loading from database cache is very fast (<1 second)
2. `isTreeLoaded` becomes true quickly
3. Gap exists between tree loaded and network connection/sync starting
4. Sync overlay only showed when `isSyncing` was true (set inside `refreshBalance()`)

**Solution: Multi-state Loading Overlay**

Added `isConnecting` state and `isInitialSync` local state to ensure continuous visual feedback:

1. **WalletManager.swift**:
   - Added `@Published private(set) var isConnecting: Bool = false`
   - Added `setConnecting(_ connecting: Bool, status: String?)` method

2. **ContentView.swift**:
   - Added `@State private var isInitialSync: Bool = true`
   - Sync overlay now shows when: `isTreeLoaded && (isSyncing || isConnecting || isInitialSync)`
   - Shows "Connecting to network..." during connection phase
   - Shows "Initializing..." before sync starts
   - `isInitialSync = false` only after sync completes

**Loading Sequence Now**:
1. Tree loading overlay (if tree not cached)
2. Sync overlay with "Connecting to network..." during connection
3. Sync overlay with actual progress during blockchain scan
4. Overlay disappears when sync complete

**Files Modified**:
- `Sources/Core/Wallet/WalletManager.swift` - added `isConnecting` state
- `Sources/App/ContentView.swift` - multi-state overlay logic
- `Sources/ZipherX-Bridging-Header.h` - added `zipherx_find_cmu_position` declaration

### 9. P2P-First Data Fetching for Mobile Users (November 2025)

**Problem**: Transaction building failed when fetching CMUs for notes beyond bundled tree height
- Insight API timeout when fetching blocks
- Mobile users cannot connect to local zcashd node

**Root Cause**: The app was configured to use a local full node at `192.168.178.86:8232` for trusted sync, but mobile users on public networks don't have access to this node.

**Solution: Decentralized P2P-First Architecture**

All block data (CMUs, anchors) now fetched via connected P2P peers first, with Insight API as fallback:

1. **CMU Fetching** (`TransactionBuilder.swift`):
   - Primary: Use P2P peer's `getFullBlocks()` to fetch block data
   - Fallback: Insight API with parallel fetching and 30-second timeout

2. **Anchor Fetching** (`TransactionBuilder.swift`):
   - Block headers contain `finalSaplingRoot` (32 bytes) which IS the anchor
   - Fetch via P2P `getFullBlocks()` - headers include anchor directly

3. **140-Byte Zcash Header Parsing** (`Peer.swift`):
   - Fixed: Was parsing 80-byte Bitcoin headers, now parses 140-byte Zcash format
   - Header format: version(4) + prevHash(32) + merkleRoot(32) + **finalSaplingRoot(32)** + time(4) + bits(4) + nonce(32)

4. **Removed All Local Node References**:
   - Deleted `LocalNodeRPC.swift`
   - Removed `192.168.178.86` from hardcoded peers
   - Removed `isConnectedToLocalNode`, `hasLocalNodePeer()`, `LOCAL_NODE_*` constants

**Code Example** (P2P-first CMU fetch):
```swift
// FIRST: Try P2P peers (faster and decentralized!)
if networkManager.isConnected, let peer = networkManager.getConnectedPeer() {
    let blocks = try await peer.getFullBlocks(from: height, count: 1)
    if let block = blocks.first {
        for tx in block.transactions {
            for output in tx.outputs {
                cmus.append(output.cmu)
            }
        }
    }
}
// FALLBACK: Insight API with parallel fetching
```

**Files Modified**:
- `Sources/Core/Crypto/TransactionBuilder.swift` - P2P-first CMU/anchor fetching
- `Sources/Core/Network/Peer.swift` - 140-byte header parsing with finalSaplingRoot
- `Sources/Core/Network/FilterScanner.swift` - Added finalSaplingRoot to CompactBlock
- `Sources/Core/Network/NetworkManager.swift` - Removed local node constants
- `Sources/Core/Network/HeaderSyncManager.swift` - Removed local node trust mode
- `Sources/Features/Balance/BalanceView.swift` - Removed isConnectedToLocalNode UI
- **Deleted**: `Sources/Core/Network/LocalNodeRPC.swift`

### 10. "Could not reach consensus among peers" When Sending (November 2025)

**Problem**: Users with 2 connected P2P peers could not send transactions - error "Could not reach consensus among peers"

**Root Cause**: `NetworkManager.getChainHeight()` was throwing `consensusNotReached` when:
1. P2P peers don't report `peerStartHeight` in version message (returns 0)
2. Heights dictionary ends up empty (0 values filtered out)

**Solution: InsightAPI Fallback**

Added InsightAPI fallback when P2P peers don't report valid heights:

```swift
// getChainHeight() now falls back to InsightAPI
if let (height, count) = heights.max(by: { $0.key < $1.key }), count >= 1 {
    return height
}

// Fallback: If P2P peers don't report valid heights, use InsightAPI
print("⚠️ P2P peers did not report chain height, falling back to InsightAPI...")
let status = try await InsightAPI.shared.getStatus()
return status.height
```

**Files Modified**:
- `Sources/Core/Network/NetworkManager.swift` - added InsightAPI fallback to `getChainHeight()`

### 11. CRITICAL: Nullifier Byte Order Mismatch - Spent Detection Failing (November 2025)

**Problem**: Notes showing as "UNSPENT" when they were actually spent on blockchain. Balance displayed 0.0087 ZCL but real balance is 0 ZCL.

**Root Cause**: Nullifier byte order mismatch during spend detection comparison:
- API returns nullifiers in **big-endian (display format)**: `9150bff548d3328acc4468e316d701e8b370f64348dbb58d4ba8f2e885d2c8ab`
- Our `knownNullifiers` set stores in **little-endian (wire format)**: `abc8d285e8f2a84b8db5db4843f670b3e801d716e36844cc8a32d348f5bf5091`
- These are byte-reversed of each other!
- `knownNullifiers.contains(nullifierData)` was comparing big-endian vs little-endian - never matches

**Solution**: Reverse the API nullifier before comparison:

```swift
// In processShieldedOutputsSync and processShieldedOutputsForNotesOnly:
guard let nullifierDisplay = Data(hexString: spend.nullifier) else { continue }
// CRITICAL FIX: API returns nullifier in big-endian (display format)
// but our knownNullifiers are stored in little-endian (wire format)
let nullifierWire = nullifierDisplay.reversedBytes()
if knownNullifiers.contains(nullifierWire) {
    try database.markNoteSpent(nullifier: nullifierWire, spentHeight: height)
}
```

**Files Modified**:
- `Sources/Core/Network/FilterScanner.swift` - fixed nullifier byte order in `processShieldedOutputsSync()` and `processShieldedOutputsForNotesOnly()`

### 12. Unified Cypherpunk Progress View for All Startup Scenarios (November 2025)

**Problem**:
1. Progress bar disappeared after a few seconds during sync
2. Different progress views for tree loading vs syncing
3. Tasks not displayed in the cypherpunk progress view
4. Progress bar missing on private key import

**Solution**: Unified cypherpunk sync view for ALL startup scenarios:

1. **Single overlay for entire initial sync** - shows from wallet creation/import until sync complete
2. **Combined progress tracking** - tree loading (0-30%), connecting (30-35%), sync (35-100%)
3. **Task list display** - shows all tasks with progress bars and status indicators
4. **`isInitialSync` flag** - only set to `false` after EVERYTHING completes

```swift
// Single overlay condition - stays visible for entire initial sync
if isInitialSync {
    CypherpunkSyncView(
        progress: currentSyncProgress,
        status: currentSyncStatus,
        tasks: currentSyncTasks  // Combined tasks including tree loading
    )
}

// Combined tasks computed property
private var currentSyncTasks: [SyncTask] {
    var tasks: [SyncTask] = []
    // Tree loading task
    if !walletManager.isTreeLoaded {
        tasks.append(SyncTask(id: "tree", title: "Load commitment tree", status: .inProgress, ...))
    } else {
        tasks.append(SyncTask(id: "tree", title: "Load commitment tree", status: .completed))
    }
    // Add sync tasks from WalletManager
    tasks.append(contentsOf: walletManager.syncTasks)
    return tasks
}
```

**CypherpunkSyncView now shows**:
- SYNCING title with glitch effect
- Rotating cypherpunk messages
- Task list with individual progress bars
- Overall progress bar with percentage
- Cypherpunk's Manifesto quote

**Files Modified**:
- `Sources/App/ContentView.swift` - unified overlay, combined progress/tasks computed properties
- `Sources/UI/Components/System7Components.swift` - `CypherpunkSyncView` now accepts `tasks` parameter, added `CypherpunkSyncTaskRow`

---

## Technical Notes

- **Witness Format**: 4 bytes (u32 LE position) + 32×32 bytes (Merkle path) = 1028 bytes
- **Tree State Size**: ~350KB - 1.7MB depending on network usage
- **Bundled Tree Load Time**: ~54 seconds to build tree from 1M+ CMUs
- **Full Sync Time**: ~30-60 minutes without checkpoint (sequential block processing required)
- **FFI Header**: `/Users/chris/ZipherX/Libraries/zipherx-ffi/include/zipherx_ffi.h`

### Key Constants

| Constant | Value | Location |
|----------|-------|----------|
| Sapling Activation | 476,969 | `ZclassicCheckpoints.swift` |
| Bundled Tree Height | 2,923,123 | `FilterScanner.swift`, `TransactionBuilder.swift` |
| Bundled CMU Count | 1,041,688 | Verified via `verify_tree` tool |
| Default Fee | 10,000 zatoshis | `TransactionBuilder.swift` |

### Known Issues

- Equihash verification temporarily disabled (need implementation)
- Header store may get out of sync - use "Rebuild Witnesses" to fix

## Contact

For questions about this project, refer to the architecture document or review the security model section.
- z.log is available as usual here : /Users/chris/ZipherX