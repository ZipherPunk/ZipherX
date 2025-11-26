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
11. **Local Full Node Trust Mode** - Connect to local zcashd for trusted sync
12. **Two-Phase Scanning** - Parallel note discovery + sequential tree building

### In Progress / Needs Testing

1. **Transaction Building** - Spend proof generation with real witnesses
2. **Full Send Flow** - End-to-end shielded transaction

### Remaining Tasks

1. **Multi-Peer Consensus** - Currently single API endpoint
2. **Background Sync** - iOS background fetch
3. **Secure Enclave Integration** - Currently keys in memory
4. **Security Audit** - Required before any real use

---

## Pre-built Bundled Commitment Tree

### Overview

The app includes a pre-built Sapling commitment tree (`commitment_tree_v2.bin`) containing all CMUs from Sapling activation to a checkpoint height. This enables instant balance display without hours of sequential scanning.

### Bundled Tree Specifications

| Property | Value |
|----------|-------|
| **File** | `Resources/commitment_tree_v2.bin` |
| **Format** | `[count: UInt64 LE][cmu1: 32 bytes][cmu2: 32 bytes]...` |
| **CMU Count** | 1,041,667 commitments |
| **End Height** | 2,922,769 |
| **File Size** | ~31 MB |
| **Tree Root** | Must match chain's `finalsaplingroot` at end height |

### How to Generate/Update the Bundled Tree

1. **Export CMUs from local node:**
```bash
cd /Users/chris/ZipherX/Libraries/zipherx-ffi
cargo run --bin export_cmus -- \
    --start 476969 \
    --end 2922769 \
    --output /Users/chris/ZipherX/Resources/commitment_tree_v2.bin
```

2. **Verify the tree root matches chain:**
```bash
# Get expected root from chain
zclassic-cli getblockheader $(zclassic-cli getblockhash 2922769) true | grep finalsaplingroot

# Verify our tree produces the same root
cargo run --bin verify_tree /Users/chris/ZipherX/Resources/commitment_tree_v2.bin
```

3. **Update `bundledTreeHeight` in code:**
   - `FilterScanner.swift` line ~83: `let bundledTreeHeight: UInt64 = 2922769`
   - `TransactionBuilder.swift` line ~98: `let bundledTreeHeight: UInt64 = 2922769`

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

## Local Full Node Trust Mode

### Purpose

When running a local Zclassic full node (`zcashd`), the app can trust it completely for faster sync without multi-peer consensus.

### Configuration

In `NetworkManager.swift`:
```swift
// Check if we have a local full node connection
var hasLocalFullNode: Bool {
    return connectedPeers.contains { peer in
        peer.host == "192.168.178.86" || peer.host == "localhost" || peer.host == "127.0.0.1"
    }
}
```

### Behavior When Local Node Detected

- Header sync uses single peer (no consensus required)
- Block data fetched directly from local node
- Transaction broadcast goes to local node first
- Logs show: `🏠 Using LOCAL FULL NODE (trusted mode)`

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

### 5. CRITICAL: CMU Byte Order in Bundled Tree (causing spend failures)
**Problem**: Transaction building failed with "bad-txns-sapling-spend-description-invalid"
- Tree root mismatch: Our tree produced different root than zcashd
- Root cause: CMUs in `commitment_tree_v2.bin` were stored with REVERSED byte order
- The export tool stored CMUs in little-endian (internal) format but the tree loader expected big-endian (display/RPC) format

**Diagnosis Steps Used**:
1. Compared first CMU in bundled file with first CMU from zcashd RPC
2. Found bytes were reversed: File had `43391df0...5a` while chain had `5a8d47a7...43`
3. Confirmed `bytes.reverse()` produces matching values

**Fix** (in `lib.rs`):
- `zipherx_tree_load_from_cmus()`: Reverse each 32-byte CMU before parsing
- `zipherx_tree_create_witness_for_cmu()`: Reverse target CMU for comparison, then reverse each CMU during tree building

```rust
// CRITICAL: Reverse bytes from little-endian storage to big-endian for parsing
let mut cmu_reversed = [0u8; 32];
for j in 0..32 {
    cmu_reversed[j] = cmu_bytes[31 - j];
}
let node = zcash_primitives::sapling::Node::read(&cmu_reversed[..])?;
```

**Files Modified**:
- `Libraries/zipherx-ffi/src/lib.rs` - lines ~1512-1520 and ~1588-1638

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
| Bundled Tree Height | 2,922,769 | `FilterScanner.swift`, `TransactionBuilder.swift` |
| Bundled CMU Count | 1,041,667 | Verified via `verify_tree` tool |
| Default Fee | 10,000 zatoshis | `TransactionBuilder.swift` |

### Known Issues

- Equihash verification temporarily disabled (need implementation)
- Header store may get out of sync - use "Rebuild Witnesses" to fix

## Contact

For questions about this project, refer to the architecture document or review the security model section.
