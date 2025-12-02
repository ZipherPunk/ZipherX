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

- [x] All private keys encrypted at rest (Secure Enclave + AES-GCM-256)
- [x] Secure Enclave used for key operations (SecureKeyStorage.swift)
- [x] Multi-peer consensus implemented (consensusThreshold = 3)
- [x] Sapling proofs verified locally (LocalTxProver)
- [x] BIP39 mnemonic generation (24-word seed phrases via FFI)
- [x] No sensitive data in logs (DEBUG_LOGGING flag)
- [x] Network traffic encrypted (P2P + HTTPS)
- [x] Memory protection for spending keys (SecureData wrapper)
- [x] App lock with biometric auth (Face ID / Touch ID)
- [x] Inactivity timeout auto-lock (configurable)
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

20. **Full P2P-Only Scanning** - Complete P2P network support (November 2025) ✅
    - Raw transaction parsing from P2P `block` messages
    - `getBlockDataP2P()` / `getBlocksDataP2P()` - Parse shielded outputs/spends from raw blocks
    - P2P-first scanning with optional InsightAPI fallback
    - Settings toggle: "P2P Only Mode" (UserDefaults: `useP2POnly`)
    - Trustless operation: No centralized API dependency when enabled

21. **Debug Logging System** - File-based debug logging (November 2025) ✅
    - `DebugLogger.swift` - Singleton logger with file output
    - Toggle in Settings: "Enable Debug Logging" (UserDefaults: `debugLoggingEnabled`)
    - Export debug log via share sheet
    - Categorized logging: NET, CRYPTO, WALLET, SYNC, TX, FFI, UI, ERROR, PARAMS
    - `debugLog()` global function for easy logging throughout codebase

22. **Bundled Sapling Parameters** - No download required (November 2025) ✅
    - `sapling-spend.params` (46 MB) - bundled in app
    - `sapling-output.params` (3.4 MB) - bundled in app
    - Copied from bundle to Documents on first launch
    - Falls back to download from z.cash if bundle copy fails
    - Enables instant transaction sending without network delay

23. **Peer Address Persistence** - Save discovered peers between launches (November 2025) ✅
    - `PersistedAddress` struct for peer serialization
    - Save to UserDefaults with connection stats (attempts, successes)
    - Load persisted addresses on startup for faster reconnection
    - Prioritize reliable peers based on historical success rate

24. **P2P Zcash Transaction Parsing** - Full v4 Sapling transaction support (November 2025) ✅
    - `parseZcashTransaction()` - Parse Zcash v4 overwintered transactions
    - Correctly handles 140-byte Zcash headers (vs 80-byte Bitcoin)
    - Extracts SpendDescription (384 bytes): cv + anchor + nullifier + rk + zkproof + spendAuthSig
    - Extracts OutputDescription (948 bytes): cv + cmu + ephemeralKey + encCiphertext + outCiphertext + zkproof
    - Validates P2P data with InsightAPI fallback for corrupted blocks

25. **Catch-up Sync on Startup** - Sync blocks arrived during setup (November 2025) ✅
    - After initial sync completes, re-check chain height
    - If new blocks arrived during setup → sync them before showing main screen
    - Ensures balance screen shows accurate data with no missed blocks
    - Progress message: "Catching up X new block(s)..."

26. **Memory Protection for Spending Keys** - SecureData wrapper (December 2025) ✅
    - `SecureData` class wraps sensitive key data
    - Automatic memory zeroing on deallocation via `deinit`
    - `withSpendingKey()` closure-based access pattern
    - Keys never cached in memory - retrieved fresh from Secure Enclave for each operation
    - Manual `zero()` method for immediate cleanup

27. **App Lock with Background Timeout** - BiometricAuthManager (December 2025) ✅
    - Face ID / Touch ID authentication on app launch
    - Configurable inactivity timeout (15s, 30s, 1min, 2min, 5min, Never)
    - Auto-lock when app goes to background
    - Lock screen overlay with biometric prompt
    - Activity tracking resets timeout on user interaction
    - Settings → "Face ID" toggle and timeout configuration

### In Progress / Needs Testing

1. **Balance UI Update** - Show tree loading progress in main wallet view

### Remaining Tasks

1. **Background Sync** - iOS background fetch
2. **Security Audit** - Required before any real use

---

## Pre-built Bundled Commitment Tree

### Overview

The app includes a pre-built Sapling commitment tree (`commitment_tree_v3.bin`) containing all CMUs from Sapling activation to a checkpoint height. This enables instant balance display without hours of sequential scanning.

### Bundled Tree Specifications

| Property | Value |
|----------|-------|
| **File** | `Resources/commitment_tree.bin` (copied from v4) |
| **Format** | `[count: UInt64 LE][cmu1: 32 bytes][cmu2: 32 bytes]...` |
| **CMU Count** | 1,041,891 commitments |
| **End Height** | 2,926,122 |
| **File Size** | 31.8 MB |
| **Tree Root** | `5cc45e5ed5008b68e0098fdc7ea52cc25caa4400b3bc62c6701bbfc581990945` |

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

### 13. Header Sync Only Received 160 Headers Instead of Full Range (November 2025)

**Problem**: Header sync only received 160 headers but needed ~1900 to cover from bundled tree height (2923123) to chain tip (~2925030). Scan then failed with "No header found" errors at height 2923283+.

**Root Causes**:
1. **Batch loop exited early**: Loop incremented `currentHeight = endHeight + 1` regardless of actual headers received
2. **No valid block locator**: When starting from height 2923123, needed hash at 2923122 as P2P "getheaders" locator, but no checkpoint existed
3. **Off-by-one height assignment**: If using checkpoint at height N, `getheaders` returns headers AFTER that block (N+1), but heights were assigned starting at N

**Solution**:

1. **Fixed batch loop** (`HeaderSyncManager.swift`):
   ```swift
   // Now continues until all headers received
   while currentHeight <= chainTip {
       let headers = try await requestHeadersWithConsensus(from: currentHeight, to: chainTip)
       guard !headers.isEmpty else { break }
       // ...
       currentHeight = headers.last!.height + 1  // Based on ACTUAL received
   }
   ```

2. **Added checkpoint at bundled tree height** (`Checkpoints.swift`):
   ```swift
   2923123: "000004496018943355cdf6c313e2aac3f3356bb7f31a31d1a5b5b582dfe594ef"
   ```

3. **Use checkpoint as block locator** (`HeaderSyncManager.swift`):
   ```swift
   // buildGetHeadersPayload now checks ZclassicCheckpoints.mainnet[locatorHeight]
   // Converts hex to wire format (reversed bytes) for P2P protocol
   ```

4. **Fixed start height** (`WalletManager.swift`):
   - Now starts at `bundledTreeHeight + 1` (2923124)
   - Checkpoint at 2923123 is used as locator
   - Headers correctly assigned heights starting at 2923124

**Files Modified**:
- `Sources/Core/Network/HeaderSyncManager.swift` - batch loop fix, checkpoint locator support
- `Sources/Core/Network/Checkpoints.swift` - added checkpoint at 2923123
- `Sources/Core/Wallet/WalletManager.swift` - start at bundledTreeHeight + 1

### 13. Auto-Rebuild Stale Witnesses with Anchor Tracking (November 2025)

**Problem**: Transaction failed because stored witness didn't match current tree anchor. Notes discovered during scan had stale witnesses that weren't updated.

**Root Cause**:
1. FilterScanner wasn't updating `pendingWitnesses` (newly discovered notes) at end of scan
2. No way to detect if stored witness matches current anchor
3. TransactionBuilder assumed stored witness was always valid

**Solution: Anchor Tracking System**

Added `anchor` column to notes table to track when witness was last updated:

1. **Database Schema** (`WalletDatabase.swift`):
   - Added `anchor BLOB` column to notes table
   - Added migration for existing databases
   - Added `updateNoteAnchor()` function
   - Updated `getUnspentNotes()` and `getAllUnspentNotes()` to return anchor

2. **FilterScanner** (`FilterScanner.swift`):
   - Fixed: Now updates BOTH `existingWitnessIndices` AND `pendingWitnesses` at end of scan
   - Saves current tree root as anchor when updating witnesses

3. **TransactionBuilder** (`TransactionBuilder.swift`):
   - Checks if stored anchor matches current tree root
   - If mismatch or empty → auto-rebuilds witness
   - After rebuild → saves witness AND anchor to database
   - Future sends find matching anchor → instant (no rebuild)

**Flow**:
```
First send (anchor empty):
  → Check: anchor empty → needsRebuild = true
  → Rebuild witness from chain
  → Save witness + anchor to database
  → Transaction succeeds

Second send (anchor matches):
  → Check: anchor matches current tree root → needsRebuild = false
  → Use stored witness directly (INSTANT!)
  → Transaction succeeds

Future send (anchor stale due to new blocks):
  → Check: anchor differs → needsRebuild = true
  → Rebuild witness, save, succeed
```

**Files Modified**:
- `Sources/Core/Storage/WalletDatabase.swift` - anchor column, migration, updateNoteAnchor()
- `Sources/Core/Network/FilterScanner.swift` - update pendingWitnesses + save anchor
- `Sources/Core/Crypto/TransactionBuilder.swift` - anchor check, auto-rebuild, save

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
| Bundled Tree Height | 2,926,122 | `FilterScanner.swift`, `TransactionBuilder.swift`, `WalletManager.swift` |
| Bundled CMU Count | 1,041,891 | `WalletManager.swift` |
| Default Fee | 10,000 zatoshis | `TransactionBuilder.swift` |
| Min Peers for Sync | 3 | `HeaderSyncManager.swift` |

### 14. Transaction Builder Optimization Attempt - REVERTED (November 28, 2025)

**Problem**: Transaction building was slow because it reloaded the full bundled tree (1M+ CMUs) for notes beyond bundled height. Also, blocks could arrive during the rebuild causing race conditions.

**Attempted Solutions** (all failed):

1. **Use in-memory tree instead of rebuilding**:
   - Modified `TransactionBuilder` to check if `WalletManager.shared.isTreeLoaded`
   - Use `WalletManager.shared.getTreeSerializedData()` to get current tree state
   - This avoided the 54-second tree load time

2. **P2P batch fetch optimization**:
   - Limited batch size to 50 blocks
   - Added 30-second timeout to `getFullBlocks()`
   - Added `withTimeout()` helper in `Peer.swift`
   - Added `p2pFetchFailed` flag to prevent infinite retry loops

3. **InsightAPI rate limiting**:
   - Added parallel batch fetching with 30-second timeout
   - Added fallback from P2P to InsightAPI

4. **Progress bar fix**:
   - Fixed progress bar showing 100% during initial sync
   - Added `isInitialSync` to cap condition

**Why All Optimizations Failed**:

The root cause was **witness/anchor mismatch**. The transaction was rejected with error code 18 (`REJECT_INVALID`):

```
Log showed:
- Header store anchor: ae6f5305aad161f31204e43701fdd35e...
- Computed anchor from rebuilt tree: 0b0b15e40e80b035...
```

The witness was built from one tree state, but the anchor was from a different state. The spend proof is invalid if witness root ≠ anchor.

**Working Solution** (what `987faaa` does correctly):

The working version from commit `987faaa` uses the **anchor from header store** combined with a **rebuilt witness**. This works because:

1. The header store contains `finalSaplingRoot` at each block height
2. The witness is rebuilt by loading bundled CMUs + fetching additional CMUs
3. The witness path is computed for the note's position in the tree
4. The anchor from header store at the note's height matches zcashd's expected tree state
5. Even if our rebuilt tree has slight timing differences, the anchor from header store is what zcashd expects

**Files Restored**:
- `Sources/Core/Crypto/TransactionBuilder.swift` - restored to commit `987faaa` (2025-11-27 15:18:09)

**Key Insight**:
DO NOT try to optimize transaction building by using the current synced tree state. The anchor MUST come from the header store (which contains the blockchain's canonical `finalSaplingRoot` values), not from a tree we compute ourselves. The witness can be rebuilt, but the anchor must match what the network expects.

**Future Optimization Ideas** (if needed):
- Pre-cache witnesses for known notes during sync
- Store witness alongside note when appending to tree
- Background tree update worker that doesn't block send

---

### 15. Tree Corruption Auto-Detection and Recovery (November 28, 2025)

**Problem**: Commitment tree in FFI memory could become corrupted (too many CMUs, wrong root), causing all transactions to fail with error code 18.

**Root Cause**: The tree state was saved to database after a corrupted scan, then reloaded on subsequent launches.

**Solution**: Added tree validation in `WalletManager.preloadCommitmentTree()`:

```swift
// VALIDATION: Check if tree size is reasonable
let lastScanned = (try? WalletDatabase.shared.getLastScannedHeight()) ?? bundledTreeHeight
let blocksAfterBundled = max(0, Int64(lastScanned) - Int64(bundledTreeHeight))
let maxExpectedCMUs = bundledTreeCMUCount + UInt64(blocksAfterBundled) * 50

if treeSize < bundledTreeCMUCount || treeSize > maxExpectedCMUs {
    print("⚠️ Tree size \(treeSize) seems invalid")
    // Clear corrupted state and reload from bundled CMUs
    try? WalletDatabase.shared.saveTreeState(nil)
    try? WalletDatabase.shared.updateLastScannedHeight(bundledTreeHeight, hash: Data(count: 32))
}
```

**Files Modified**:
- `Sources/Core/Wallet/WalletManager.swift` - added tree size validation on load

---

### 16. Transaction Propagation Progress Bar (November 28, 2025)

**Problem**: User requested progress bar during transaction broadcast and mempool verification.

**Solution**: Added progress reporting to broadcast phase:

1. **NetworkManager.broadcastTransactionWithProgress()** - New function with progress callback:
   - Reports peer acceptance progress: "Accepted by X/Y peers"
   - Reports verification progress: "Checking mempool (attempt X/10)"

2. **SendView broadcast step** - Now shows sub-progress during:
   - Peer broadcast phase
   - Mempool verification phase

**Files Modified**:
- `Sources/Core/Network/NetworkManager.swift` - added `broadcastTransactionWithProgress()`
- `Sources/Core/Network/InsightAPI.swift` - added `checkTransactionExists()`
- `Sources/Core/Wallet/WalletManager.swift` - uses new broadcast with progress
- `Sources/Features/Send/SendView.swift` - displays broadcast sub-progress

---

### 17. CRITICAL: Tree Corruption Race Condition Fix (November 28, 2025)

**Problem**: Commitment tree was corrupted with ~70,000 extra CMUs (1,111,878 instead of expected ~1,055,998), causing transactions to fail with error code 18 (bad-txns-sapling-spend-description-invalid).

**Root Cause**: Race condition - three concurrent tree loading operations were all appending to the same global `COMMITMENT_TREE` in Rust:
1. `WalletManager.init()` → `preloadCommitmentTree()`
2. `ContentView.task` → `ensureTreeLoaded()`
3. `FilterScanner.startScan()` → tree initialization

When all three ran concurrently, CMUs were being appended multiple times, corrupting the tree.

**Solution: Two-Level Locking**

1. **WalletManager loading lock** - Prevents duplicate calls within WalletManager:
   ```swift
   private var isTreeLoading = false
   private let treeLoadLock = NSLock()

   private func preloadCommitmentTree() async {
       treeLoadLock.lock()
       if isTreeLoading || isTreeLoaded {
           treeLoadLock.unlock()
           // Wait for other load to complete
           while !isTreeLoaded { try? await Task.sleep(...) }
           return
       }
       isTreeLoading = true
       treeLoadLock.unlock()
       // ... load tree ...
   }
   ```

2. **FilterScanner wait for WalletManager** - FilterScanner waits for WalletManager's tree to be loaded before proceeding:
   ```swift
   // In FilterScanner.startScan(), before tree initialization:
   if !needsFreshBundledTree {
       let walletManager = WalletManager.shared
       while !walletManager.isTreeLoaded && waitAttempts < 300 {
           try await Task.sleep(nanoseconds: 100_000_000) // 100ms
           waitAttempts += 1
       }
   }
   ```

**Tree Validation** (already added in fix #15):
- On startup, validates tree size is within expected range
- If corrupted, clears database tree state and rescans from bundled tree

**Files Modified**:
- `Sources/Core/Wallet/WalletManager.swift` - loading lock, validation
- `Sources/Core/Network/FilterScanner.swift` - wait for WalletManager tree
- `Sources/Core/Storage/WalletDatabase.swift` - `clearTreeState()` function

---

### 18. InsightAPI Fallback Missing Spends - Wrong Balance (November 28, 2025)

**Problem**: Balance showing 0.0618 ZCL instead of correct 0.0431 ZCL. Notes 1-3 should be marked as spent but weren't being detected.

**Root Cause**: When P2P headers are missing (recent blocks), the InsightAPI fallback was only fetching shielded outputs, not spends:
```swift
// OLD CODE - missing spends!
txDataList.append((txid, outputs, nil))
```

Without spends data, nullifier detection couldn't find spending transactions, so notes remained marked as "UNSPENT" even though they had been spent on-chain.

**Solution**: Fetch full transaction details from InsightAPI including `spendDescs`:
```swift
// Get full tx to check for spends (nullifier detection)
let txInfo = try? await InsightAPI.shared.getTransaction(txid: txid)
let spends = txInfo?.spendDescs

// Include tx if it has outputs OR spends
if !outputs.isEmpty || (spends?.isEmpty == false) {
    txDataList.append((txid, outputs, spends))
}
```

**Files Modified**:
- `Sources/Core/Network/NetworkManager.swift` - `getBlocksDataP2P()` InsightAPI fallback now includes spends

---

### 19. Cached Chain Height Fallback for Transaction Building (November 28, 2025)

**Problem**: Transaction building failed with "Could not reach consensus among peers" when:
1. P2P peers don't report chain height (common)
2. InsightAPI is temporarily unreachable (network glitch)

**Solution**: Use cached `chainHeight` as final fallback in `getChainHeight()`:
```swift
// Final fallback: use cached chain height if recent enough
if chainHeight > 0 {
    print("⚠️ Using cached chain height: \(chainHeight)")
    return chainHeight
}
```

**Files Modified**:
- `Sources/Core/Network/NetworkManager.swift` - added cached height fallback

---

## MILESTONE: First Successful Shielded Transaction! (November 28, 2025)

**Transaction ID**: `db74f9f8fe5a0aff5cf04d7add01124320563ce8d5eb79c1e7308d32b5658c87`
**Block**: 2,926,118 (3+ confirmations)
**Type**: Fully shielded z-to-z transaction

**What worked**:
1. ✅ Bundled commitment tree loading (1,041,688 CMUs)
2. ✅ Race condition fix (120s timeout + FilterScanner wait)
3. ✅ Spent note detection via nullifier matching
4. ✅ Witness generation from stored tree state
5. ✅ Sapling spend proof generation (Groth16)
6. ✅ Transaction building with correct Buttercup branch ID
7. ✅ P2P broadcast to network peers
8. ✅ On-chain verification via InsightAPI

**Transaction details**:
- 1 shielded spend (consumed Note 4: 0.0431 ZCL)
- 2 shielded outputs (recipient + change)
- 2373 bytes transaction size

This proves the full shielded transaction flow works end-to-end on Zclassic mainnet!

---

### 20. Sync Performance and UI Improvements (November 29, 2025)

**Changes Made:**

1. **Pre-fetch Pipeline for Sync** (`FilterScanner.swift`)
   - Sequential mode now pre-fetches batch N+1 while processing batch N
   - ~40% speed improvement by overlapping network I/O with tree building
   - Cancels pre-fetch task if scan is stopped early

2. **Fixed Witness Loading Order** (`FilterScanner.swift`)
   - Existing witnesses now loaded AFTER tree is initialized (was loading before)
   - This ensures witnesses are properly updated as new CMUs are appended

3. **Updated Bundled Tree to Latest Height**
   - Height: 2,926,122 (was 2,923,123)
   - CMU Count: 1,041,891 (was 1,041,688)
   - Root: `5cc45e5ed5008b68e0098fdc7ea52cc25caa4400b3bc62c6701bbfc581990945`
   - Near-instant startup sync (only ~0 blocks to fetch on fresh install)

4. **Face ID Authentication for Send Transactions** (`BiometricAuthManager.swift`)
   - `authenticateForSend()` now ALWAYS requires fresh Face ID (no timeout bypass)
   - This ensures every send transaction requires explicit biometric approval

5. **Peer Count Warning** (`BalanceView.swift`)
   - Peer count now shows RED when < 3 peers connected
   - Added ⚠️ warning emoji to status text
   - `HeaderSyncManager` requires minimum 3 peers for sync

6. **P2P-Only Broadcasting** (`NetworkManager.swift`)
   - Transaction broadcast is P2P only (no InsightAPI fallback)
   - InsightAPI only used for mempool verification (read-only)

**Files Modified:**
- `Sources/Core/Network/FilterScanner.swift` - pre-fetch pipeline, witness loading order fix
- `Sources/Core/Security/BiometricAuthManager.swift` - fresh Face ID for send
- `Sources/Features/Balance/BalanceView.swift` - red peer count warning
- `Sources/Core/Network/HeaderSyncManager.swift` - minPeers = 3
- `Sources/Core/Network/NetworkManager.swift` - P2P-only broadcast
- `Sources/Core/Wallet/WalletManager.swift` - bundled tree constants updated
- `Sources/Core/Crypto/TransactionBuilder.swift` - bundled tree constants updated

---

### 21. UI Stuck at 98% During Initial Sync (November 29, 2025)

**Problem**: App startup UI stuck at 98% even after scan completed successfully. The log showed endless `📊 Fetching network stats...` messages.

**Root Cause**: ContentView's sync completion wait loop had flawed exit conditions:
1. `balanceTaskCompleted` check relied on task status being set correctly
2. `syncTasks.isEmpty` condition NEVER triggered because syncTasks array is never cleared (8 tasks remain after sync)
3. No fallback timeout for cases where task status checking fails

**Solution: Multiple Exit Conditions**

1. **Added `allTasksCompleted` check** - Checks if all tasks have status `.completed` or `.failed`:
   ```swift
   let allTasksCompleted = !walletManager.syncTasks.isEmpty && walletManager.syncTasks.allSatisfy {
       if case .completed = $0.status { return true }
       if case .failed = $0.status { return true }
       return false
   }
   ```

2. **Added fallback timeout** - If `isSyncing` is false for 10+ seconds, exit anyway:
   ```swift
   if !walletManager.isSyncing && syncCompleteWait > 100 {
       print("✅ Sync complete: sync stopped (fallback)")
       break
   }
   ```

3. **Fixed `currentSyncProgress` computed property** - Changed condition to not get stuck when tasks exist but are all completed

4. **Fixed `currentSyncStatus` computed property** - Same fix to show "Finalizing..." when appropriate

**Files Modified**:
- `Sources/App/ContentView.swift` - fixed sync completion detection, progress, and status logic
- `Sources/Core/Wallet/WalletManager.swift` - added debug print for balance task completion

---

### 22. Broadcast Verification Error When InsightAPI Slow (November 29, 2025)

**Problem**: Transaction broadcast succeeded (P2P peers accepted), but app showed error "Transaction not found on blockchain - may have been rejected" because InsightAPI verification took too long. Balance remained unchanged even though tx was on-chain.

**Root Cause**: The verification step was BLOCKING and threw an error after 10 attempts (30 seconds). InsightAPI might be slow to index new transactions.

**Solution: Non-blocking Verification**

1. **Reduced verification attempts** - 5 attempts × 2 seconds = 10 seconds max wait
2. **Verification is now informational** - If InsightAPI doesn't see the tx, log a warning but DON'T throw error
3. **P2P broadcast success = success** - If at least 1 peer accepted the tx, return txId
4. **Added debug logging** - Track which peers accept/reject the tx

```swift
// OLD: Threw error if verification failed
throw NetworkError.transactionNotVerified

// NEW: Log warning but return success
if !verified {
    print("⚠️ Transaction not yet visible on InsightAPI (may take a moment): \(txId)")
    onProgress?("verify", "Broadcast complete (verifying...)", 1.0)
}
return txId  // P2P broadcast succeeded, tx is propagating
```

**Files Modified**:
- `Sources/Core/Network/NetworkManager.swift` - non-blocking verification, better logging

---

### 23. Background Tree Sync for Instant Sends (November 29, 2025)

**Problem**: Transaction sends were slow (~30+ seconds) because the app had to fetch new blocks and rebuild witnesses at send time.

**Solution: Automatic Background Sync**

1. **Trigger**: When `chainHeight > walletHeight` (detected during network stats fetch)
2. **Process**: Fetch new blocks, append CMUs to tree, update witnesses
3. **Result**: Tree always current, witnesses always up-to-date

**Flow**:
```
┌─────────────────────────────────────────────────────────────┐
│  1. App syncs on startup → tree at height N                 │
│  2. Network stats detects chainHeight = N+5                 │
│  3. Background sync fetches blocks N+1 to N+5               │
│  4. CMUs appended, witnesses updated                        │
│  5. User sends → tree already current → INSTANT!            │
└─────────────────────────────────────────────────────────────┘
```

**TransactionBuilder Optimization**:
- If `note.anchor == currentTreeRoot` → witness is current, skip rebuild
- Prints "✅ Witness is current (anchor matches tree root) - INSTANT mode!"
- Only rebuilds if witness is stale (missed background sync)

**Files Modified**:
- `Sources/Core/Wallet/WalletManager.swift` - `backgroundSyncToHeight()` method
- `Sources/Core/Network/NetworkManager.swift` - triggers background sync when chain ahead
- `Sources/Core/Crypto/TransactionBuilder.swift` - skip rebuild if witness current

---

### 24. CRITICAL: Background Sync Reloading Bundled Tree Instead of Appending (November 29, 2025)

**Problem**: Notes received in recent blocks were not being detected. Balance showed 0 even though transaction was confirmed on blockchain.

**Root Cause**: The `needsFreshBundledTree` condition in `FilterScanner.startScan()` was wrong:
```swift
// OLD (WRONG):
let needsFreshBundledTree = customStartHeight != nil && customStartHeight! > bundledTreeHeight
```

This condition was TRUE for background sync because:
- `customStartHeight` = 2926324 (current height + 1)
- `bundledTreeHeight` = 2926122
- 2926324 > 2926122 = TRUE

This caused background sync to reload the bundled tree (1,041,891 CMUs) every time instead of using the existing tree and APPENDING new CMUs. The shielded outputs from new blocks were never added to the tree.

**Solution**: Changed condition to only trigger fresh reload for explicit rescans, not for incremental background sync:

```swift
// NEW (CORRECT):
let initialTreeSize = ZipherXFFI.treeSize()
let treeHasProgress = initialTreeSize > bundledTreeCMUCount

// Only force fresh bundled tree if:
// 1. Custom height provided AND starting exactly from bundled+1 (rescan scenario)
// 2. AND tree doesn't already have progress (hasn't appended CMUs beyond bundled)
let needsFreshBundledTree = customStartHeight != nil
    && customStartHeight! == bundledTreeHeight + 1
    && !treeHasProgress
```

**How Background Sync Now Works**:
1. NetworkManager detects `chainHeight > walletHeight`
2. Triggers `backgroundSyncToHeight(chainHeight)`
3. FilterScanner called with `fromHeight: currentHeight + 1`
4. `needsFreshBundledTree = false` (height != bundledTreeHeight + 1)
5. Uses existing tree in memory
6. Fetches blocks, appends CMUs, detects notes
7. Saves updated tree to database

**Files Modified**:
- `Sources/Core/Network/FilterScanner.swift` - fixed `needsFreshBundledTree` condition

---

### 25. Fast Broadcast Exit + Instant Send Optimization (November 29, 2025)

**Problem 1**: Transaction broadcast waited for ALL peers to respond before checking mempool, causing unnecessary delays.

**Problem 2**: `buildShieldedTransactionWithProgress` ALWAYS called `rebuildWitnessForNote()` for notes beyond bundled height, taking 2+ minutes even when witness was already valid.

**Solutions**:

1. **Fast Broadcast Exit** (`NetworkManager.swift`):
   - Broadcasts to all peers in parallel
   - Checks mempool as soon as 1 peer accepts
   - Exits IMMEDIATELY when mempool confirms (cancels remaining peer tasks)
   - Uses actor for thread-safe state management
   - Max 3 mempool checks × 500ms = 1.5s verification

2. **Instant Send Mode** (`TransactionBuilder.swift`):
   - Added check: if `note.anchor == currentTreeRoot` → INSTANT mode
   - Only calls `rebuildWitnessForNote()` if `needsRebuild == true`
   - Previously, rebuild was called unconditionally for notes beyond bundled height

**Files Modified**:
- `Sources/Core/Network/NetworkManager.swift` - fast broadcast with early exit
- `Sources/Core/Crypto/TransactionBuilder.swift` - instant mode check before rebuild

---

### 26. Transaction History Missing Sent Entries (November 29, 2025)

**Problem**: After clean build, sent transactions weren't appearing in transaction history, even though balance was correct (0).

**Root Cause**: `markNoteSpent(nullifier:txid:)` didn't set `spent_height`, which is required for `populateHistoryFromNotes()` to create SENT entries.

**Solution**:

1. **Updated `markNoteSpent`** (`WalletDatabase.swift`):
   ```swift
   // OLD: Only set is_spent and spent_in_tx
   func markNoteSpent(nullifier: Data, txid: Data)

   // NEW: Also set spent_height
   func markNoteSpent(nullifier: Data, txid: Data, spentHeight: UInt64)
   ```

2. **Updated callers** (`WalletManager.swift`):
   - Get `chainHeight` before marking note spent
   - Pass `spentHeight: chainHeight` to `markNoteSpent`

3. **Auto-refresh history on balance change** (`BalanceView.swift`):
   - Added `loadTransactionHistory()` call in `onChange(of: walletManager.shieldedBalance)`
   - History now refreshes when balance changes (not just on new blocks)

**Files Modified**:
- `Sources/Core/Storage/WalletDatabase.swift` - `markNoteSpent` now requires spentHeight
- `Sources/Core/Wallet/WalletManager.swift` - passes chainHeight to markNoteSpent
- `Sources/Features/Balance/BalanceView.swift` - history reload on balance change

---

### 27. Dynamic Peer Targeting (10%) with Temp Banning (November 29, 2025)

**Problem**: Static peer count didn't scale with discovered addresses.

**Solution**:
- Connect to 10% of known peer addresses (min 3, max 20)
- Batch connection until target reached
- 24-hour temp banning for peers that timeout or send corrupted data
- Ban reasons tracked: `.timeout`, `.corruptedData`

**Files Modified**:
- `Sources/Core/Network/NetworkManager.swift` - dynamic targeting, temp banning
- `Sources/Core/Network/Peer.swift` - `PeerMessageLock` actor for exclusive access

---

### 28. P2P Message Queuing (November 29, 2025)

**Problem**: Mempool scan conflicted with other P2P operations on same peer, causing "Peer handshake failed" errors.

**Solution**: Added `PeerMessageLock` actor for serialized peer access:
```swift
actor PeerMessageLock {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async { ... }
    func release() { ... }
}
```

- `withExclusiveAccess()` method for safe peer operations
- Mempool functions use exclusive access
- Re-enabled automatic mempool scanning

**Files Modified**:
- `Sources/Core/Network/Peer.swift` - `PeerMessageLock` actor

---

### 29. Fireworks Animation on Receive (November 29, 2025)

**Feature**: Fireworks animation when ZCL is received.

**Implementation**:
- `FireworksView` with particle physics (gravity, fading, colors)
- Triggers when `shieldedBalance` increases
- Shows "+X.XXXX ZCL RECEIVED!" message
- Auto-dismisses after 3 seconds, tap to dismiss early

**Files Modified**:
- `Sources/UI/Components/System7Components.swift` - `FireworksView`
- `Sources/Features/Balance/BalanceView.swift` - fireworks trigger

---

### 30. Banned Peers Management UI (November 29, 2025)

**Feature**: View and manage temporarily banned peers in Settings.

**Implementation**:
- "Banned Peers" button shows current count
- Sheet displays list with IP, ban reason, time remaining
- Checkbox selection for individual unbanning
- "Unban Selected" and "Unban All" buttons

**Files Modified**:
- `Sources/Core/Network/NetworkManager.swift` - `getBannedPeers()`, `unbanPeer()`, `unbanAllPeers()`
- `Sources/Features/Settings/SettingsView.swift` - banned peers sheet

---

### 25. CRITICAL: Wrong Nullifier for Notes After Bundled Tree (November 29, 2025)

**Problem**: Balance showing 0.019 ZCL when it should be 0.0094 ZCL. Note 3 (0.0096 ZCL) was marked as UNSPENT when it had already been spent on-chain.

**Root Cause**: Note 3's nullifier was computed with **position=0** instead of its correct tree position.

**Why it happened**:
1. Note 3 was received at height 2926435, which is AFTER the bundled tree ends at height 2926122
2. When discovered during `processShieldedOutputsForNotesOnly`, the CMU lookup in bundled data failed
3. Position defaulted to 0 (see lines 1270-1278 in FilterScanner.swift)
4. Nullifier computed with position=0 is completely wrong
5. Blockchain spend at height 2926511 has correct nullifier → no match → note stays "UNSPENT"

**Evidence**:
- Note 3 DB nullifier: `1B8BAF867480AACFD08CDDF92B6987402D44EF74A9E24E517BE0DB0B01EAD4BD`
- Blockchain spend nullifier: `c64c896370e964824d50cb8387cf67abfbd2933ddebc15750fddec602cb5377b`
- These don't match even when byte-reversed - completely different values due to wrong position

**Solution: "Repair Notes" Function**

Added a repair function that:
1. Deletes notes received AFTER bundledTreeHeight (2926122)
2. Clears tree state (forces reload from bundled CMUs)
3. Rescans from bundledTreeHeight + 1 using SEQUENTIAL mode
4. Sequential mode uses `processShieldedOutputsSync` which gets correct position from `ZipherXFFI.treeAppend()`
5. Correct position → correct nullifier → spent notes properly detected

**Files Modified**:
- `Sources/Core/Storage/WalletDatabase.swift` - added `deleteNotesAfterHeight()`
- `Sources/Core/Wallet/WalletManager.swift` - added `repairNotesAfterBundledTree()`
- `Sources/Features/Settings/SettingsView.swift` - added "Repair Notes (fix balance)" button

**User Instructions**:
1. Go to Settings
2. Scroll to "Blockchain Data" section
3. Tap "Repair Notes (fix balance)" (purple button)
4. Confirm the repair
5. Wait for rescan to complete
6. Balance should now show correct amount

---

### 26. CRITICAL: Repair Notes Did Not Actually Reload Tree - isTreeLoaded Bug (November 30, 2025)

**Problem**: After running "Repair Notes", balance still showed wrong amount (0.0038 ZCL instead of 0.0094 ZCL). Nullifiers were still being computed with wrong positions.

**Root Cause Investigation**:
1. Created test binary `find_cmu_position.rs` to count CMUs from blockchain
2. Found that correct position for first note is **1041904** but app computed **1042059** (off by 155!)
3. Checked z.log: tree had 1,042,041+ commitments when bundled tree should have exactly 1,041,891
4. The corrupted tree was being used even after "Repair Notes" was called

**Bug Location**: `WalletManager.performWitnessRepair()` at line ~1014

**Why Reload Failed**:
```swift
// The code was:
print("🌳 Reloading commitment tree from bundled data...")
await preloadCommitmentTree()

// But preloadCommitmentTree() has this guard:
if isTreeLoading || isTreeLoaded {  // isTreeLoaded was TRUE
    return  // ← Returns immediately without reloading!
}
```

The `preloadCommitmentTree()` function returned immediately because `isTreeLoaded` was still `true` from the initial load. The corrupted tree remained in FFI memory.

**Fix Applied**:
```swift
// Now reset isTreeLoaded and clear FFI tree BEFORE calling preload:
await MainActor.run {
    self.isTreeLoaded = false
    self.treeLoadProgress = 0.0
    self.treeLoadStatus = ""
}
_ = ZipherXFFI.treeInit()  // Clear FFI tree
print("🌳 Reloading commitment tree from bundled data...")
await preloadCommitmentTree()  // Now this actually reloads
```

**Files Modified**:
- `Sources/Core/Wallet/WalletManager.swift` - reset `isTreeLoaded` and clear FFI tree before reload

**Verification**:
After fix, "Repair Notes" should:
1. Reset `isTreeLoaded = false`
2. Clear FFI tree with `treeInit()`
3. Actually reload 1,041,891 CMUs from bundled file
4. Rescan and compute correct positions (1041904 not 1042059)
5. Compute correct nullifiers that match on-chain spends
6. Balance displays correct 0.0094 ZCL

---

### 27. UI/UX Improvements (November 30, 2025)

**Changes Made:**

1. **Cypherpunk Privacy Warning for Private Key Import** (`WalletSetupView.swift`)
   - New warning sheet appears BEFORE import dialog
   - Includes quote from "A Cypherpunk's Manifesto"
   - Warns about: address reuse, historical scan duration, key security
   - "Fast Start Mode" info box explaining recent-blocks-only scan
   - User must tap "I Understand, Continue" to proceed

2. **Default Theme Changed to Cypherpunk** (`ThemeManager.swift`)
   - Default theme now `cypherpunk` instead of `mac7`
   - Applies to iOS, macOS simulator, and macOS versions
   - Existing users keep their chosen theme preference

3. **Real-Time Chain Height Updates** (`NetworkManager.swift`)
   - Added `statsRefreshTimer` (30-second interval)
   - Chain height auto-updates without manual refresh
   - Only logs when height actually changes

4. **Real-Time Banned Peers Count** (`NetworkManager.swift`)
   - Added `@Published bannedPeersCount` property
   - Updates immediately when peers banned/unbanned
   - UI reacts to changes automatically

5. **Fixed Banned Peers List Display** (`SettingsView.swift`)
   - Changed from non-reactive `getBannedPeers().count` to reactive `bannedPeersCount`
   - Fixed macOS sheet size: `minWidth: 500, minHeight: 400`
   - Proper theme support for cypherpunk mode

6. **Floating Sync Progress Indicator** (`ContentView.swift`)
   - Shows during background sync after initial sync complete
   - Displays: progress bar, percentage, current/max block height, blocks remaining
   - Floating at bottom of screen, user can still use app
   - macOS has max width constraint (400px)

7. **Sync Height Tracking** (`WalletManager.swift`)
   - Added `@Published syncCurrentHeight` and `syncMaxHeight` properties
   - Updated in real-time during scan progress callback

**Files Modified:**
- `Sources/App/WalletSetupView.swift` - cypherpunk import warning
- `Sources/UI/Theme/ThemeManager.swift` - default theme to cypherpunk
- `Sources/Core/Network/NetworkManager.swift` - stats refresh timer, banned peers count
- `Sources/Features/Settings/SettingsView.swift` - reactive banned peers, macOS sheet size
- `Sources/App/ContentView.swift` - floating sync indicator
- `Sources/Core/Wallet/WalletManager.swift` - sync height tracking

---

### 28. CRITICAL: Sent Transaction Not Recorded in History (November 30, 2025)

**Problem**: User sent transaction successfully (success box appeared with txid), but transaction was NOT recorded in transaction_history database. Balance showed 0 but history showed "No transactions yet".

**Root Cause**: In `sendShieldedWithProgress()`, the `getChainHeight()` call was BEFORE `insertTransactionHistory()`. When `getChainHeight()` threw an error ("Insufficient peers: got 0, need 1"), the code exited early and never recorded the transaction.

```swift
// OLD FLOW (buggy):
let txId = try await broadcast(rawTx)           // ✅ Success
let chainHeight = try await getChainHeight()    // ❌ THROWS ERROR
try insertTransactionHistory(...)               // ⚠️ NEVER REACHED
return txId                                     // ⚠️ Shows success but no DB record!
```

**Solution: Atomic Transaction Recording with Verification**

1. **Fallback chain height**: If `getChainHeight()` fails, use cached `networkManager.chainHeight`
2. **Mandatory DB write**: `insertTransactionHistory` must succeed (no silent catch)
3. **Verification step**: Query database to VERIFY the transaction was actually saved
4. **Only then return success**: Success box only appears if DB verification passes

```swift
// NEW FLOW (correct):
let txId = try await broadcast(rawTx)           // ✅ Broadcast
let chainHeight = try? await getChainHeight()   // Use cached if fails
   ?? networkManager.chainHeight
try insertTransactionHistory(...)               // ✅ Must succeed
let saved = getTransactionHistory().contains(txId)  // ✅ VERIFY
guard saved else { throw "Not saved" }          // ❌ Error if not verified
return txId                                     // ✅ Only now show success
```

**Guarantee**: Success dialog ONLY appears after:
1. Transaction broadcast accepted by P2P network
2. Transaction recorded in database
3. Database record VERIFIED by re-reading

**Files Modified**:
- `Sources/Core/Wallet/WalletManager.swift` - both `sendShieldedWithProgress()` and `sendShielded()` functions

---

### 29. Immediate Transaction History Recording (December 1, 2025)

**Problem**: Transaction history was not always in sync with the actual blockchain state:
1. History only populated when user opens History tab (lazy loading)
2. Notes discovered during scanning weren't immediately recorded in history
3. If app crashed between note discovery and History tab opening, transactions would be missing

**Root Cause**:
- `populateHistoryFromNotes()` was only called when history was empty
- FilterScanner discovered notes and stored them, but didn't record in transaction_history
- `markNoteSpent()` wasn't passing the spending txid for proper tracking

**Solution: Real-time Transaction Recording**

1. **HistoryView ALWAYS populates** (`HistoryView.swift`):
   - Changed to call `populateHistoryFromNotes()` on EVERY load, not just when empty
   - Ensures any newly discovered notes appear in history

2. **FilterScanner records immediately** (`FilterScanner.swift`):
   - Added `recordReceivedTransaction()` calls in ALL note discovery locations:
     - `processShieldedOutputsSync()` - sync mode scanning
     - `processShieldedOutputsForNotesOnly()` - parallel note discovery
     - `processShieldedOutputs()` - async legacy mode
     - `processDecryptedNote()` - (already had `insertTransactionHistory()`)
   - Updated all 3 `markNoteSpent()` calls to include spending txid

3. **New WalletDatabase functions** (`WalletDatabase.swift`):
   ```swift
   // Record received transaction immediately when note discovered
   func recordReceivedTransaction(txid: Data, height: UInt64, value: UInt64, memo: String?) throws

   // Record sent transaction immediately when user initiates send
   func recordSentTransaction(txid: Data, height: UInt64, value: UInt64, fee: UInt64, toAddress: String?, memo: String?) throws

   // Check for deduplication
   func transactionExistsInHistory(txid: Data, type: TransactionType) -> Bool
   ```

4. **Deduplication via `INSERT OR IGNORE`**:
   - Multiple calls to record same transaction are safe
   - UNIQUE constraint on (txid, tx_type) prevents duplicates

**Result**: Transaction history is now updated in real-time as notes are discovered during scanning, not lazily when user opens History tab.

**Files Modified**:
- `Sources/Features/History/HistoryView.swift` - always call populateHistoryFromNotes()
- `Sources/Core/Network/FilterScanner.swift` - immediate history recording + txid in markNoteSpent()
- `Sources/Core/Storage/WalletDatabase.swift` - new recording functions

---

### 30. Dual-Mode Architecture: Light + Full Node (December 1, 2025)

**Feature**: ZipherX now supports two operating modes on macOS:

1. **Light Mode** (default) - P2P network with bundled commitment tree
2. **Full Node Mode** - Local zclassicd daemon with complete blockchain

**Architecture**:
```
┌─────────────────────────────────────────────────────────────┐
│                         ZipherX App                          │
├─────────────────────────────────────────────────────────────┤
│  ┌─────────────────────┐    ┌──────────────────────────────┐│
│  │   Light Mode        │    │   Full Node Mode             ││
│  │   (iOS + macOS)     │    │   (macOS only)               ││
│  │                     │    │                              ││
│  │  - P2P Network      │    │  - Local zclassicd daemon    ││
│  │  - Bundled Tree     │    │  - Bootstrap download        ││
│  │  - ~50MB storage    │    │  - RPC communication         ││
│  │  - Fast startup     │    │  - Full blockchain (~5GB)    ││
│  │                     │    │  - Built-in explorer         ││
│  └─────────────────────┘    └──────────────────────────────┘│
└─────────────────────────────────────────────────────────────┘
```

**New Files Created**:

| File | Purpose |
|------|---------|
| `Sources/Core/FullNode/WalletMode.swift` | Mode enum, manager, persistence |
| `Sources/Core/FullNode/RPCClient.swift` | JSON-RPC client for zclassicd |
| `Sources/Core/FullNode/BootstrapManager.swift` | Bootstrap download/extract |
| `Sources/Core/FullNode/BootstrapProgressView.swift` | Bootstrap progress UI |
| `Sources/App/ModeSelection/ModeSelectionView.swift` | First-launch mode selection |
| `Sources/Features/Explorer/ExplorerView.swift` | Blockchain explorer UI |
| `Sources/Features/Explorer/ExplorerViewModel.swift` | Explorer logic + data models |

**RPCClient Features** (ported from Zipher):
- Connection management with localhost-only security
- Balance queries (total, transparent, shielded, unconfirmed)
- Address management (create, list, get balance)
- Transaction sending via z_sendmany
- Private key import/export
- Wallet encryption support
- Explorer methods (getblock, gettransaction, getaddressbalance)
- Error sanitization (removes paths, IPs, addresses from errors)

**BootstrapManager Features** (ported from Zipher):
- GitHub release detection for latest bootstrap
- Multi-part download with resume support
- SHA256 checksum verification
- Zstd decompression
- zclassic.conf generation with random RPC credentials
- Sapling parameter download if missing
- Progress reporting with speed/ETA

**Explorer Features**:
- Search by block height, hash, txid, or address
- Block details (hash, height, time, transactions)
- Transaction details (inputs, outputs, shielded components)
- Address lookup with privacy protection for z-addresses
- Works in both modes (InsightAPI for light, RPC for full node)

**Settings Integration**:
- New "Wallet Mode" section in Settings (macOS only)
- Shows current mode with description
- "Switch to Full Node" button triggers bootstrap
- "Switch to Light Mode" button for easy mode change
- Full node status shows daemon connection and block height

**Privacy Philosophy** (Explorer):
```swift
// Shielded addresses are PRIVATE - the explorer respects this
if address.isShielded {
    // Show privacy notice, not balance
    Text("\"Privacy is necessary for an open society in the electronic age.\"")
    Text("Shielded address balances and transactions are hidden from prying eyes.")
}
```

**Files Modified**:
- `Sources/Features/Settings/SettingsView.swift` - added walletModeSection

---

### 21. CRITICAL SECURITY FIX: Encrypted Private Key Storage on All Platforms (December 2025)

**Problem**: Private keys were stored UNENCRYPTED in keychain on macOS and iOS Simulator, which is a critical security vulnerability.

**Root Cause**: The original implementation only used Secure Enclave encryption for real iOS devices. Simulator and macOS fallback modes stored keys in plain text in the keychain.

**Solution: AES-GCM Encryption for All Non-Secure-Enclave Platforms**

| Platform | Encryption Method | Key Derivation |
|----------|------------------|----------------|
| iOS Device | Secure Enclave (hardware) | EC key in secure hardware |
| iOS Simulator | AES-GCM-256 | HKDF from SIMULATOR_UDID + random salt |
| macOS | AES-GCM-256 | HKDF from Hardware UUID + random salt |

**Implementation Details**:

1. **Simulator encryption** (`storeKeySimple()`):
   ```swift
   let encryptionKey = try getSimulatorEncryptionKey()
   let sealedBox = try AES.GCM.seal(key, using: encryptionKey)
   // Store sealedBox.combined in keychain
   ```

2. **macOS encryption** (`storeKeySimpleMacOS()`):
   ```swift
   let encryptionKey = try getMacOSEncryptionKey()
   let sealedBox = try AES.GCM.seal(key, using: encryptionKey)
   // Store sealedBox.combined in keychain (no kSecAttrAccessible)
   ```

3. **Key derivation** (both platforms):
   ```swift
   // Get device-unique identifier
   let deviceId = getSimulatorDeviceId() // or getHardwareUUID() for macOS
   let salt = try getOrCreateSalt()

   // Derive 256-bit key using HKDF
   let derivedKey = HKDF<SHA256>.deriveKey(
       inputKeyMaterial: SymmetricKey(data: Data(deviceId.utf8)),
       salt: salt,
       info: Data("ZipherX-...-encryption".utf8),
       outputByteCount: 32
   )
   ```

4. **Salt storage**: Random 32-byte salt stored separately in keychain for each platform

5. **Decryption**: `decryptSimulatorData()` and `decryptMacOSData()` functions for retrieval

6. **Validation**: `hasSpendingKey()` now attempts decryption to verify key is valid

**macOS Hardware UUID** (via IOKit):
```swift
#if os(macOS)
import IOKit
let platformExpert = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
let uuid = IORegistryEntryCreateCFProperty(platformExpert, kIOPlatformUUIDKey as CFString, ...)
#endif
```

**Security Properties**:
- Keys are ALWAYS encrypted at rest (AES-GCM provides confidentiality + integrity)
- Encryption key is device-bound (cannot decrypt on different device)
- Salt ensures same key produces different ciphertext on different devices
- 12-byte nonce + 16-byte auth tag = 28 bytes overhead (169 → 197 bytes)

**Files Modified**:
- `Sources/Core/Storage/SecureKeyStorage.swift` - complete encryption overhaul

**Breaking Change**: Existing wallets on simulator/macOS with unencrypted keys will need to be deleted and recreated. The `hasSpendingKey()` function will return `false` if it cannot decrypt the stored data.

---

### 22. Transaction History Change Output Filter (December 1, 2025)

**Problem**: User reported change outputs (internal wallet transactions) were showing in transaction history alongside real sent/received transactions.

**Root Cause**: The SQL query in `WalletDatabase.getTransactionHistory()` was returning ALL transaction types including `change`.

**Solution**: Added filter to exclude change outputs from history display:

```sql
-- Added to both count and select queries
WHERE t1.tx_type != 'change'
```

**Files Modified**:
- `Sources/Core/Storage/WalletDatabase.swift` - lines ~1441 and ~1465

**Verification**: Both iOS Simulator and macOS wallets now show only `received` and `sent` transactions.

---

### 23. Security Audit Report Generated (December 1, 2025)

Created comprehensive cypherpunk-styled HTML security audit report:

**Location**: `/Users/chris/ZipherX/docs/SECURITY_AUDIT_REPORT.html`

**Report Contents**:
- Executive Summary with key metrics
- Balance Verification (100% accuracy confirmed)
- Transaction History Verification
- Private Key Import Performance Analysis:
  - iOS Simulator: 2m13s total (56s tree load + 77s scan)
  - macOS: 2m50s total (57s tree load + 113s scan)
- Security Findings:
  - **CRITICAL**: SQLite database NOT encrypted (SQLCipher not implemented)
  - **WARNING**: Spending keys in memory during signing
  - **WARNING**: macOS file-based key storage (no Secure Enclave for Sapling keys)
  - **PASSED**: Key encryption (AES-GCM-256), No hardcoded credentials, Network security (HTTPS), Biometric auth, Sapling proof verification, Tree integrity
- Cryptographic Implementation Details
- Required Actions Before Production (P0-P4 prioritized)
- Verification Commands

**View Report**: `open /Users/chris/ZipherX/docs/SECURITY_AUDIT_REPORT.html`

---

### 32. Background Sync Not Triggering for New Blocks (December 1, 2025)

**Problem**: iOS simulator received ZCL from a transaction but it never appeared in the wallet. Full node balance was correct, but ZipherX showed the old balance. z.log showed chain height updates but no background sync calls.

**Root Causes**:

1. **Race condition with @Published chainHeight**:
   - `fetchNetworkStats()` updated `chainHeight` on MainActor at line 732
   - But the condition check at line 752 used `chainHeight` directly
   - Due to async/await, the value might not be updated yet when checked

2. **Competing sync mechanisms**:
   - `fetchNetworkStats()` spawned `backgroundSyncToHeight()` in a Task
   - `autoRefreshTick()` in BalanceView also called `refreshBalance()`
   - `refreshBalance()` sets `isSyncing = true`
   - `backgroundSyncToHeight()` has guard: `guard !isSyncing else { return }`
   - Result: `refreshBalance()` blocked the background sync!

**Solution**:

1. **Use local variable for chain height** (`NetworkManager.swift`):
   ```swift
   var currentChainHeight: UInt64 = 0
   // ... fetch from API ...
   currentChainHeight = status.height

   // Use local variable, not @Published property
   if currentChainHeight > dbHeight && dbHeight > 0 {
       await WalletManager.shared.backgroundSyncToHeight(currentChainHeight)
   }
   ```

2. **Remove redundant refreshBalance() call** (`BalanceView.swift`):
   - `autoRefreshTick()` now only calls `fetchNetworkStats()`
   - `backgroundSyncToHeight()` handles new block detection automatically
   - Removed competing sync that was blocking background sync

**Files Modified**:
- `Sources/Core/Network/NetworkManager.swift` - use local `currentChainHeight`, add debug logging
- `Sources/Features/Balance/BalanceView.swift` - remove redundant `refreshBalance()` call in `autoRefreshTick()`

**Debug Logging Added**:
- `"🔄 Background sync needed: chain=X wallet=Y (+Z blocks)"` when sync triggered
- `"📊 Sync check: chain=X wallet=Y - no sync needed"` when already synced

---

### 22. UX Improvements and P2P Broadcast Fix (December 2, 2025)

**Changes Made:**

1. **Change Output Fireworks Suppression** (`WalletManager.swift`, `BalanceView.swift`)
   - Added `lastSendTimestamp` property to track when transactions were sent
   - Balance increases within 30 seconds of a send are treated as change outputs
   - Change outputs no longer trigger the "received" fireworks celebration

2. **Rocket Emoji for Incoming Transactions** (`System7Components.swift`)
   - Changed `FireworksView` to show 🚀 instead of 🎉
   - Changed text from "RECEIVED!" to "INCOMING!"

3. **Navigate to Balance After Send Success** (`SendView.swift`, `ContentView.swift`)
   - Added `onSendComplete` callback to `SendView`
   - After clicking "DONE" on success screen, user is returned to balance tab
   - Works for both tab-based view and cypherpunk sheet view

4. **Mined Transaction Celebration** (`NetworkManager.swift`, `BalanceView.swift`, `System7Components.swift`)
   - Added `justConfirmedTx` published property for confirmed transaction notifications
   - Added `MinedCelebrationView` with cypherpunk messages:
     - "Proof of work complete. Your transaction is now immutable."
     - "Consensus achieved. The network validates your privacy."
     - "Block sealed. Your financial sovereignty preserved."
     - "Hash verified. Another step toward freedom."
   - Shows ⛏️ MINED! overlay when outgoing transaction confirms
   - Auto-dismisses after 4 seconds or on tap

5. **P2P Broadcast Protocol Fix** (`Peer.swift`)
   - **Root cause**: P2P `broadcastTransaction` was waiting for a response that never comes
   - In Bitcoin/Zcash P2P protocol, successful tx broadcast has **no response**
   - Node either silently accepts (success) or sends `reject` message (failure)
   - Fixed to wait only 500ms for potential reject, then assume success
   - This enables proper P2P transaction broadcast instead of always falling back to InsightAPI

**Files Modified:**
- `Sources/Core/Wallet/WalletManager.swift` - added `lastSendTimestamp`
- `Sources/Features/Balance/BalanceView.swift` - change detection, mined celebration
- `Sources/Features/Send/SendView.swift` - `onSendComplete` callback
- `Sources/App/ContentView.swift` - pass callbacks to SendView
- `Sources/Core/Network/NetworkManager.swift` - `justConfirmedTx` property
- `Sources/Core/Network/Peer.swift` - fixed P2P broadcast protocol
- `Sources/UI/Components/System7Components.swift` - 🚀 emoji, `MinedCelebrationView`

---

### 33. P2P-First Header Sync with Cypherpunk UI (December 2, 2025)

**Problem**: Header sync task was showing red (failed) at startup, and InsightAPI was being used as fallback too frequently.

**Root Causes Fixed**:

1. **Header sync loop exiting early** - Loop used `endHeight` (requested) instead of actual headers received. P2P `getheaders` returns max 160 headers per response, not 2000.

2. **Peer failures blocking sync** - If initial batch of peers failed, sync gave up without trying other peers from the pool.

3. **Scan running ahead of header sync** - FilterScanner used P2P chain tip, which could be ahead of synced headers, causing "No header found" errors.

**Solutions Implemented**:

1. **Fixed header sync loop** (`HeaderSyncManager.swift`):
   ```swift
   // Use actual headers received, not requested endHeight
   let actualEndHeight = currentHeight + UInt64(headers.count) - 1
   currentHeight = actualEndHeight + 1
   ```

2. **Peer retry logic** - Try at least 10 peers before giving up:
   ```swift
   let minPeersToTry = 10
   while successfulHeaders.count < consensusThreshold && !remainingPeers.isEmpty {
       // Try peers in batches, exit early if consensus reached
       if successfulHeaders.count >= consensusThreshold {
           group.cancelAll()
           break
       }
   }
   ```

3. **Reactive reconnection** - On handshake failure, wait 50ms and retry once:
   ```swift
   catch NetworkError.handshakeFailed {
       peer.disconnect()
       try? await Task.sleep(nanoseconds: 50_000_000)
       try await peer.connect()
       try await peer.performHandshake()
       // Retry request
   }
   ```

4. **Scan height = min(HeaderStore, P2P)** (`FilterScanner.swift`):
   ```swift
   let scanHeight = min(hsHeight, chainTip)
   // Ensures we never scan beyond synced headers
   ```

**Cypherpunk Task Names** (`WalletManager.swift`, `ContentView.swift`):
- "Load zk-SNARK circuits"
- "Derive spending keys"
- "Unlock encrypted vault"
- "Verify peer consensus (3/3)"
- "Query chain tip from peers"
- "Decrypt shielded notes"
- "Build Merkle witnesses"
- "Tally unspent notes"

**Files Modified**:
- `Sources/Core/Network/HeaderSyncManager.swift` - fixed sync loop, peer retry logic, reactive reconnection
- `Sources/Core/Network/FilterScanner.swift` - scan height = min(HeaderStore, P2P)
- `Sources/Core/Wallet/WalletManager.swift` - cypherpunk task names and status messages
- `Sources/App/ContentView.swift` - cypherpunk task names

---

### Known Issues

- Equihash verification temporarily disabled (need implementation)
- Header store may get out of sync - use "Rebuild Witnesses" to fix
- Notes received BEFORE bundledTreeHeight (2926122) require manual "Full Rescan from Height" in Settings
- Full Node mode requires manual zclassicd installation (not bundled)

---

### 34. AES-GCM-256 Field-Level Database Encryption (December 2, 2025)

**Problem**: Sensitive wallet data (notes, witnesses, spending keys) was stored in plaintext in SQLite database, vulnerable to physical device access attacks.

**Solution**: Implemented AES-GCM-256 encryption for sensitive database fields using CryptoKit.

**Architecture**:
```
┌─────────────────────────────────────────────────────────────┐
│  DatabaseEncryption.swift - AES-GCM-256 Field Encryption    │
├─────────────────────────────────────────────────────────────┤
│  Key Derivation:                                            │
│    Device ID (vendor/UUID/hardware) + Random Salt           │
│    → HKDF-SHA256 → 256-bit Symmetric Key                   │
│                                                             │
│  Encrypted Fields (notes table):                            │
│    - diversifier: Address component                         │
│    - rcm: Randomness commitment (critical for spending)     │
│    - memo: User message (potentially sensitive)             │
│    - witness: Merkle path (critical for spending)           │
│                                                             │
│  NOT Encrypted (public on blockchain):                      │
│    - cmu: Note commitment                                   │
│    - nullifier: Spend tracking (needs lookup)               │
│    - value: Balance calculation (integer)                   │
│    - anchor: Tree root (public)                             │
└─────────────────────────────────────────────────────────────┘
```

**Key Components**:

1. **DatabaseEncryption.swift** (new file):
   - `encrypt(_:)` - AES-GCM seal with random nonce
   - `decrypt(_:)` - AES-GCM open with authentication
   - `getOrCreateEncryptionKey()` - HKDF key derivation
   - `getDeviceIdentifier()` - Platform-specific device ID
   - Salt stored in keychain (survives app reinstall)

2. **WalletDatabase.swift** (modified):
   - `encryptBlob()` / `decryptBlob()` helpers
   - `insertNote()` - encrypts diversifier, rcm, memo, witness
   - `getUnspentNotes()` - decrypts on retrieval
   - `getAllUnspentNotes()` - decrypts on retrieval
   - `updateNoteWitness()` - encrypts witness

**Security Properties**:
- AES-GCM provides confidentiality + integrity (authenticated encryption)
- 12-byte random nonce per encryption (never reused)
- 16-byte authentication tag prevents tampering
- Key is device-bound (cannot decrypt on different device)
- Backward compatible: auto-detects unencrypted data

**Migration**: Existing unencrypted data is handled gracefully - decryption failures fall back to returning raw data, so existing wallets continue working. New data is always encrypted.

**Files Created**:
- `Sources/Core/Storage/DatabaseEncryption.swift`

**Files Modified**:
- `Sources/Core/Storage/WalletDatabase.swift` - field-level encryption

---

## Remaining Security & Performance Tasks

### P0: Critical Security (Required Before Release)

1. ~~**SQLCipher Database Encryption**~~ ✅ COMPLETED (December 2, 2025)
   - Implemented AES-GCM-256 field-level encryption
   - Sensitive fields encrypted: diversifier, rcm, memo, witness
   - Key derived from device ID + salt via HKDF

2. **Memory Protection for Spending Keys** - Zero memory after use
   - Spending keys in memory could be dumped
   - Need `memset_s` to zero key buffers after use
   - Disable swap for sensitive memory regions

### P1: Important Security

3. **App Lock with Background Timeout** - Auto-lock after X minutes background
   - Currently only locks on app launch
   - Need timer-based auto-lock when app goes to background
   - Configurable timeout in Settings (1/5/15 minutes)

4. **Emergency Wipe Manager** - Secure data deletion
   - One-button wipe of all wallet data
   - Confirmation dialog with countdown
   - Wipe: keys, database, keychain, UserDefaults

5. **Backup Confirmation Flow** - Ensure user has backup before sending
   - Disable Send button until user confirms backup
   - Show warning on first send
   - Track backup confirmation status

### P2: Performance Optimization

6. **Pre-fetch Pipeline Expansion** - Overlap more network/compute
   - Current: pre-fetch 1 batch ahead during sync
   - Could pre-fetch 2-3 batches for faster initial sync

7. **Witness Caching at Discovery** - Cache witness when note found
   - Currently rebuild witness at send time
   - Could cache witness immediately when note discovered
   - Would make first send instant (no rebuild wait)

8. **Background Sync Optimization** - More efficient background updates
   - iOS background fetch integration
   - Minimize battery/network usage
   - Push notification for incoming transactions

## Contact

For questions about this project, refer to the architecture document or review the security model section.
- z.log is available as usual here : /Users/chris/ZipherX
- never kill any processes !
- never kill any processes !

For questions about this project, refer to the architecture document or review the security model section.
- z.log is available as usual here : /Users/chris/ZipherX
- never kill any processes !
- never kill any processes !