# Transaction Debugging Guide

## ROOT CAUSE FOUND: Wrong Branch ID (November 27, 2025)

Transaction broadcasts were failing with error code 16: `bad-txns-sapling-spend-description-invalid`

### The Problem

The wallet was using **Sapling branch ID (0x76b809bb)** but Zclassic's current active consensus requires **Buttercup branch ID (0x930b540d)**.

**Verification from running zclassicd:**
```bash
$ zclassic-cli getblockchaininfo
{
  "chain": "main",
  "blocks": 2923977,
  "consensus": {
    "chaintip": "930b540d",
    "nextblock": "930b540d"
  }
}
```

### Why This Causes Transaction Rejection

The branch ID is embedded in the **sighash personalization** used for transaction signatures:

```
BLAKE2b(personalization = "ZcashSigHash" || BRANCH_ID_LE, ...)
```

Per ZIP-243, `librustzcash_sapling_check_spend()` verifies the `spendAuthSig` against a sighash computed with the node's current branch ID. If the wallet signs with Sapling (0x76b809bb) but the node expects Buttercup (0x930b540d), the signature verification fails.

### Zclassic Network Upgrade History

| Upgrade | Branch ID | Activation Height | Notes |
|---------|-----------|-------------------|-------|
| Overwinter | `0x5ba81b19` | 476,969 | Same as Zcash |
| Sapling | `0x76b809bb` | 476,969 | Same as Zcash |
| Bubbles | `0x821a451c` | 585,318 | Zclassic-specific (Zcash: Blossom 0x2bb40e60) |
| **Buttercup** | `0x930b540d` | **707,000** | **CURRENTLY ACTIVE** (Zcash: Heartwood 0xf5b9230b) |

Source: `/Users/chris/zclassic/zclassic/src/consensus/upgrades.cpp` and `chainparams.cpp`

---

## FIX APPLIED: Local Fork of zcash_primitives (November 27, 2025)

Since `zcash_primitives` crate hardcodes Zcash branch IDs, we created a local fork with Zclassic Buttercup support.

### Files Modified

#### 1. `/Users/chris/ZipherX/Libraries/zcash_primitives_zcl/src/consensus.rs`

Added `ZclassicButtercup` variant to `BranchId` enum:
```rust
/// Zclassic Buttercup network upgrade (post-Sapling fork from Zcash).
/// Branch ID: 0x930b540d
ZclassicButtercup,
```

Added to `TryFrom<u32>` for BranchId:
```rust
0x930b_540d => Ok(BranchId::ZclassicButtercup),
```

Added to `From<BranchId>` for u32:
```rust
BranchId::ZclassicButtercup => 0x930b_540d,
```

Added `ZclassicButtercup` to `NetworkUpgrade` enum and its `branch_id()` function:
```rust
NetworkUpgrade::ZclassicButtercup => BranchId::ZclassicButtercup,
```

Added to `UPGRADES_IN_ORDER` constant:
```rust
const UPGRADES_IN_ORDER: &[NetworkUpgrade] = &[
    NetworkUpgrade::Overwinter,
    NetworkUpgrade::Sapling,
    NetworkUpgrade::Blossom,
    NetworkUpgrade::Heartwood,
    NetworkUpgrade::Canopy,
    NetworkUpgrade::Nu5,
    NetworkUpgrade::ZclassicButtercup, // Zclassic-specific
];
```

#### 2. `/Users/chris/ZipherX/Libraries/zipherx-ffi/Cargo.toml`

Changed to use local fork:
```toml
# Using local fork with Zclassic Buttercup branch ID support
zcash_primitives = { path = "../zcash_primitives_zcl" }
```

#### 3. `/Users/chris/ZipherX/Libraries/zipherx-ffi/src/lib.rs`

Updated `ZclassicNetwork::activation_height()`:
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

### How It Works

1. `BranchId::for_height()` iterates `UPGRADES_IN_ORDER` in reverse
2. For Zclassic at height 2,923,000+:
   - Nu5, Canopy, Heartwood, Blossom return `None` (not activated)
   - ZclassicButtercup returns `Some(707000)` and is active
3. Transaction builder uses `BranchId::ZclassicButtercup` (0x930b540d)
4. Sighash personalization matches node's expected branch ID
5. spendAuthSig verification passes

### Verification Test Results

```
Testing ZipherX FFI Branch ID Support
=====================================
Library version: 3

Testing branch IDs at various heights:
Height 476,969 (Sapling activation): 0x76b809bb  ✅
Height 700,000 (before Buttercup): 0x76b809bb   ✅
Height 707,000 (Buttercup activation): 0x930b540d  ✅
Height 2,923,000 (current chain): 0x930b540d  ✅

Verifying Buttercup support:
Has Buttercup support: true

✅ SUCCESS: Library correctly supports ZclassicButtercup!
```

### New Debug Functions Added

The library now includes functions to verify branch ID support:

```c
// C API
uint32_t zipherx_version(void);  // Returns 3 for Buttercup support
uint32_t zipherx_get_branch_id(uint64_t height);  // Returns branch ID for height
bool zipherx_verify_buttercup_support(void);  // Returns true if Buttercup works
```

```swift
// Swift API
ZipherXFFI.version()  // Returns 3
ZipherXFFI.getBranchId(height: 2923000)  // Returns 0x930b540d
ZipherXFFI.verifyButtercupSupport()  // Returns true
ZipherXFFI.debugBranchId(chainHeight: 2923000)  // Prints debug info
```

---

## Previous Investigation Summary (For Reference)

Transaction still rejected despite:
- ✅ Branch ID correct (Sapling 0x76b809bb)
- ✅ Note CMU matches tree CMU
- ✅ Anchor matches finalsaplingroot at block 2923169
- ✅ Witness root matches anchor
- ✅ Spend added successfully
- ✅ Transaction builds (2373 bytes)

### Remaining Suspects

1. **Proof parameters** - Are sapling-spend.params correct?
2. **Witness format** - IncrementalWitness serialization may be wrong
3. **Nullifier derivation** - May be computed incorrectly
4. **Anchor in spend description** - Byte order may be wrong in final tx

### Debug Output Added

The library now outputs:
- `🔍 SPEND DESCRIPTION DEBUG:` - Shows cv, anchor, nullifier, rk
- `📜 RAW TX HEX:` - Full transaction hex for decode analysis

### Decoded Transaction Analysis (07:31:44)

```json
{
  "txid": "8b0c59560c8aa636a4a0cd1f3994c1469e3b7529eaa2727b9b08a2aeb03eb912",
  "version": 4,
  "versiongroupid": "892f2085",  // Sapling - CORRECT
  "expiryheight": 2923968,
  "vShieldedSpend": [{
    "cv": "aa10cb0372ef1b7d53783207b03bbbf608a05fbace7c0c95966eaddb8bb4f972",
    "anchor": "544dc4813498cd51c4c40794247cc800dd8cbc70a1e534a03630eee7948f24de",  // Matches finalsaplingroot@2923169 ✅
    "nullifier": "9150bff548d3328acc4468e316d701e8b370f64348dbb58d4ba8f2e885d2c8ab",
    "rk": "539a46c5ae95c83f74210aac70e9389e694439f0efc412989e987db9f44f6e2f"
  }],
  "vShieldedOutput": [2 outputs]
}
```

**Verified:** Anchor matches zcashd's finalsaplingroot at block 2923169.

### Next Investigation Steps

Since branch ID and anchor are correct, the issue is likely:
1. **Groth16 proof verification** - The zkproof bytes may be computed with wrong inputs
2. **spendAuthSig** - The signature may be over wrong sighash
3. **Sapling parameters** - Double-check params file integrity

---

## Investigation Summary (November 2025)

### What's Been Verified as CORRECT:

1. **Note CMU matches tree CMU** - CONFIRMED
   - Computed CMU: `cd4b521af763f1805b499e8616e6df442e156de9f3e0d3e1fa02aa7a1a59ad5b`
   - Expected CMU: `cd4b521af763f1805b499e8616e6df442e156de9f3e0d3e1fa02aa7a1a59ad5b`
   - Debug output: `"✅ Computed CMU MATCHES expected tree CMU!"`

2. **Bundled tree root matches zcashd finalsaplingroot** - CONFIRMED
   - Wire format: `f302c782a2168ef5451142ffe9fa083de72b633a68ad6070a2e87d931fa1d642`
   - Display format: `42d6a11f937de8a27060ad683a632be73d08fae9ff421145f58e16a282c702f3`
   - Matches zcashd at height 2923123

3. **Witness root matches computed anchor** - CONFIRMED
   - Witness root: `de248f94e7ee3036a034e5a170bc8cdd00c87c249407c4c451cd983481c44d54`
   - Display: `544dc4813498cd51c4c40794247cc800dd8cbc70a1e534a03630eee7948f24de`
   - Matches zcashd finalsaplingroot at height 2923169

4. **Byte order consistency** - CONFIRMED
   - `treeLoadFromCMUs` uses `Node::read()` (expects wire format/LE)
   - `treeAppend` uses `Node::read()` (fixed from `Scalar::from_repr`)
   - Bundled file stores CMUs in wire format (correct)

5. **Note position correct** - CONFIRMED
   - Note at position 1041691 (4th CMU after bundled tree ends)
   - Bundled tree has 1041688 CMUs (positions 0-1041687)
   - Additional CMUs: pos 1041688, 1041689, 1041690, 1041691 (our note)

### What STILL Might Be Wrong:

1. **Merkle path construction**
   - The witness serialization produces 472 bytes (variable length)
   - This is padded to 1028 bytes for consumption
   - The Merkle path may be incorrectly encoded

2. **Proof generation inputs**
   - The proof may be generated with incorrect parameters
   - Value commitment or randomness might be wrong

3. **Nullifier derivation**
   - Nullifier is derived from note + spending key
   - If the key derivation is subtly wrong, nullifier won't match

4. **Anchor format in transaction**
   - Anchor is passed as 32 bytes
   - May need different byte order in transaction vs verification

## Key Code Locations

### FFI Library (lib.rs)

| Function | Line | Purpose |
|----------|------|---------|
| `zipherx_build_transaction` | ~830 | Main transaction builder |
| `zipherx_tree_load_from_cmus` | ~1527 | Load bundled tree |
| `zipherx_tree_append` | ~1189 | Append single CMU |
| `zipherx_tree_get_witness` | ~1365 | Get witness for position |
| `zipherx_tree_create_witness_for_cmu` | ~1587 | Find CMU and create witness |

### Swift Code

| File | Function | Purpose |
|------|----------|---------|
| `TransactionBuilder.swift` | `buildShieldedTransaction` | Main tx builder |
| `TransactionBuilder.swift` | `rebuildWitnessForNote` | Rebuild witness for notes beyond bundled tree |
| `FilterScanner.swift` | `startScan` | Find notes in blockchain |
| `WalletManager.swift` | `sendShielded` | Orchestrates sending |

## Debugging Steps

### 1. Verify anchor is recognized by zcashd

```bash
# Get the anchor we're using (wire format)
ANCHOR="de248f94e7ee3036a034e5a170bc8cdd00c87c249407c4c451cd983481c44d54"

# Find which block has this finalsaplingroot
# The anchor should match some historical finalsaplingroot
for height in 2923169 2923168 2923167; do
  root=$(zclassic-cli getblockheader $(zclassic-cli getblockhash $height) | jq -r .finalsaplingroot)
  echo "Height $height: $root"
done
```

### 2. Verify Merkle path

The witness contains a Merkle path of 32 hashes. To verify:

1. Start at the CMU position
2. Hash with sibling at each level up to root
3. Result should equal anchor

### 3. Check note reconstruction

The note is reconstructed from:
- `diversifier` (11 bytes)
- `value` (8 bytes)
- `rcm` (32 bytes - note commitment randomness)

All must match what was decrypted when the note was discovered.

### 4. Test with zcashd directly

```bash
# Try to decode and verify the raw transaction
zclassic-cli decoderawtransaction <raw_tx_hex>

# Check spend description
# vShieldedSpend[0] should have:
# - anchor: matches historical finalsaplingroot
# - nullifier: valid
# - cv: value commitment
# - proof: valid groth16 proof
```

## Potential Fixes to Try

### 1. Check proof parameters

The Sapling parameters might not be loaded correctly:
- `sapling-spend.params` (48MB)
- `sapling-output.params` (4MB)

### 2. Verify witness encoding

The witness format should be:
```
[position: 4 bytes LE]
[path_hashes: 32 * 32 bytes]
= 1028 bytes total
```

But `zcash_primitives` uses a different serialization format (variable length).

### 3. Check anchor byte order in transaction

The transaction may expect anchor in display format (big-endian) not wire format.

### 4. Verify spend key derivation

The spending key (169 bytes) should produce correct:
- `ask` (32 bytes) - spend authorizing key
- `nsk` (32 bytes) - nullifier secret key
- `ovk` (32 bytes) - outgoing viewing key

## Error Codes Reference

| Code | Name | Meaning |
|------|------|---------|
| 16 | bad-txns-sapling-spend-description-invalid | Spend proof verification failed |
| 17 | bad-txns-sapling-output-description-invalid | Output proof failed |
| 18 | bad-txns-sapling-binding-signature-invalid | Binding sig failed |

## Next Steps

1. **Add debug output for anchor byte order** in transaction serialization
2. **Print the full witness data** and compare with expected format
3. **Try broadcasting to local zcashd** with verbose logging enabled
4. **Check if proof generation is using correct parameters**

## Useful Commands

```bash
# Check zcashd debug log
tail -f ~/Library/Application\ Support/Zclassic/debug.log | grep -E "Sapling|invalid|reject"

# Get finalsaplingroot at specific height
zclassic-cli getblockheader $(zclassic-cli getblockhash 2923169) | jq .finalsaplingroot

# Verify a raw transaction
zclassic-cli decoderawtransaction <hex>
```

## Key Findings Log

| Date | Finding |
|------|---------|
| 2025-11-26 | Fixed byte order mismatch between treeLoadFromCMUs and treeAppend |
| 2025-11-26 | Verified bundled tree root matches zcashd |
| 2025-11-26 | Confirmed note CMU matches tree CMU |
| 2025-11-27 | Transaction still rejected despite correct CMU/anchor - investigating proof |
| 2025-11-27 | **ROOT CAUSE FOUND**: Wrong branch ID! Node expects Buttercup (0x930b540d), wallet was using Sapling (0x76b809bb) |
| 2025-11-27 | Created local fork of zcash_primitives with ZclassicButtercup branch ID |
| 2025-11-27 | Updated ZclassicNetwork to activate ZclassicButtercup at height 707,000 |
| 2025-11-27 | **TRANSACTIONS NOW WORKING**: Successfully broadcast shielded transactions to mainnet |
| 2025-11-27 | Fixed broadcast success detection - now only requires 1 peer acceptance |
| 2025-11-27 | Removed excessive debug logs from FFI library for production |
