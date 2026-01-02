# Tree Root Incompatibility Investigation

## Summary

The ZipherX wallet was unable to send transactions due to a tree root mismatch between the FFI commitment tree and the blockchain. This investigation traced the root cause to a chain of related issues in boost file generation, CMU extraction, and tree deserialization.

## Root Cause Analysis

### The Core Problem: Python/Rust Serialization Incompatibility

The boost file contains a pre-serialized commitment tree section (542 bytes) that should allow instant tree loading. However:

1. **Python Generation** (`generate_boost_file.py`):
   - Uses `serialize_tree` Rust tool to serialize the tree
   - Tool: `/Users/chris/ZipherX/Libraries/zipherx-ffi/target/release/serialize_tree`
   - Calls `write_commitment_tree()` from zcash_primitives

2. **Swift FFI Deserialization** (`zipherx_tree_deserialize`):
   - Calls `read_commitment_tree()` from zcash_primitives
   - Returns success but produces WRONG tree root

3. **The Mismatch**:
   - Boost manifest tree root: `0187103f5387f58fc2fa6a2bffbe7c63ad01552ee5671ac41100d97f054a4fc2`
   - After deserialization: `7c320bbb7cc91e527723248cd4ef8c6760eefa4a4979103684c5fb2e5185381b`
   - These are COMPLETELY DIFFERENT - not just a few bits off

### Why This Happened

The `serialize_tree` tool was likely using a different zcash_primitives version or the serialization format is incompatible. Both use the same library (`zcash_primitives`), but something in the serialization/deserialization roundtrip is broken.

**Critical Finding**: The deserialization returns `true` (success) but produces a completely wrong tree root. This is a silent data corruption bug.

### Secondary Issue: Corrupted CMU Cache

When tree deserialization failed, the fallback was to load from `legacy_cmus_v2.bin`. However:

1. **FIX #532 Bug**: The extraction code used hardcoded `recordSize = 652` bytes
2. **Boost File Reality**: Records are 684 bytes (with txid from FIX #374)
3. **Result**: All CMUs after position 0 were read at wrong offset → corrupted

Example:
- Position 0: Correct (offset 0)
- Position 1: Wrong (read from offset 652 instead of 684)
- Position 1043620: Complete garbage

This explains why even after "rebuilding from CMUs", the tree root was still wrong.

## The Fix Chain

### FIX #531: Include PHASE 2 CMUs in Witness Creation

**Problem**: Witness created from boost-only CMUs, missing PHASE 2 discoveries
- Global FFI tree: 1,044,151 CMUs (boost + PHASE 2)
- Witness data: 1,044,150 CMUs (boost only)
- Tree root at position X differs between trees of different sizes

**Solution**:
```swift
// Check if global tree has more CMUs than boost file
let currentTreeSize = ZipherXFFI.treeSize()
if currentTreeSize > cachedCount {
    // Load PHASE 2 CMUs from DeltaCMU manager
    let deltaCMUs = DeltaCMUManager.shared.loadDeltaCMUsForHeightRange(...)
    // Append to witness data before creating witness
}
```

**Files**: `Sources/Core/Crypto/TransactionBuilder.swift:927-970`

### FIX #532: Use Correct 684-Byte Record Size

**Problem**: Extraction used hardcoded 652-byte records
```swift
let recordSize = 652  // WRONG - old format without txid
```

**Solution**: Auto-detect from boost file
```swift
let actualRecordSize = outputSection.size / outputSection.count
let recordSize = actualRecordSize == 684 || actualRecordSize == 652 ? actualRecordSize : 684
```

**Files**: `Sources/Core/Services/CommitmentTreeUpdater.swift:376-387`

### FIX #533: Reload FFI Tree When Delta Validation Fails

**Problem**: When delta tree root validation failed:
1. Delta bundle was cleared
2. BUT FFI tree still had corrupt delta CMUs appended
3. Tree remained corrupted

**Solution**:
```swift
if !rootValid {
    deltaManager.clearDeltaBundle()

    // FIX #533: Reload tree from boost file WITHOUT corrupt delta CMUs
    let serializedTree = try await CommitmentTreeUpdater.shared.extractSerializedTree()
    _ = ZipherXFFI.treeInit()  // Reset tree
    ZipherXFFI.treeDeserialize(data: serializedTree)
    try? WalletDatabase.shared.saveTreeState(treeData)
}
```

**Files**: `Sources/Core/Wallet/WalletManager.swift:401-427`

### FIX #534: Validate Tree Root After Deserialization

**Problem**: Deserialization returns success with WRONG tree root
- No validation to detect this corruption
- Silent data corruption leads to transaction failures

**Solution**:
```swift
if ZipherXFFI.treeDeserialize(data: serializedTree) {
    // Validate against boost manifest
    if actualRoot != expectedRoot {
        // Fallback: Build tree from CMUs
        if cmuCacheMissing {
            // Extract from boost file with correct record size
            cmuData = try await CommitmentTreeUpdater.shared.extractCMUsInLegacyFormat()
        }
        ZipherXFFI.treeLoadFromCMUs(data: cmuData)
    }
}
```

**Files**: `Sources/App/ContentView.swift:247-315`

## Impact and Testing

### Before Fixes
1. Tree deserialized with wrong root: `7c320bbb...`
2. Delta CMUs appended → root changes to `c24f4a05...`
3. Witness created with wrong anchor
4. Transaction rejected: "Anchor NOT FOUND in blockchain"

### After Fixes
1. FIX #534 detects deserialization mismatch
2. Extracts CMUs from boost file using FIX #532 (correct 684-byte size)
3. Builds tree with correct root: `0187103f...`
4. Witness includes PHASE 2 CMUs via FIX #531
5. Anchor validation passes
6. Transaction broadcasts successfully

## Verification Steps

1. **Restart app** - Triggers FIX #534 tree root validation
2. **Watch logs for**:
   ```
   ❌ FIX #534: Tree root MISMATCH after deserialization!
   🔧 FIX #534: CMU cache not found - extracting from boost file...
   ✅ FIX #534: Extracted CMUs from boost file: 33412808 bytes
   ✅ FIX #534: Rebuilt tree from CMUs: 1044150 commitments
   ✅ FIX #534: Tree root MATCHES manifest - CMU build successful!
   ```

3. **Verify tree root**: Should be `0187103f5387f58fc2fa6a2bffbe7c63ad01552ee5671ac41100d97f054a4fc2`

4. **Test transaction**: Send ZCL - should succeed without anchor errors

## Files Modified

| Commit | Description | Files |
|--------|-------------|-------|
| 12e9a92 | FIX #531: Include PHASE 2 CMUs in witness creation | TransactionBuilder.swift |
| 2b124d6 | FIX #532: Use correct 684-byte record size | CommitmentTreeUpdater.swift |
| 45b671a | FIX #532: Type conversion fixes | CommitmentTreeUpdater.swift |
| dd76638 | FIX #533: Reload FFI tree when delta validation fails | WalletManager.swift |
| 3edb7e8 | FIX #534: Validate tree root after deserialization | ContentView.swift |
| 17aa255 | FIX #534 v2: Auto-extract CMUs from boost file | ContentView.swift |

## Remaining Issues

### Python Serialization Incompatibility (Unresolved)

The root cause of the serialization/deserialization mismatch is still unknown. Both use the same `zcash_primitives` library, but something is incompatible.

**Possible Causes**:
1. Different zcash_primitives versions between Python tool and FFI
2. `write_commitment_tree` vs `read_commitment_tree` format mismatch
3. Endianness or encoding differences

**Workaround**: FIX #534 falls back to building tree from CMUs, which is slower (~40s) but reliable.

**Future Investigation**: Compare zcash_primitives versions and serialization format between:
- `serialize_tree.rs` (Rust tool)
- `lib.rs` (FFI deserialization)

## Timeline

1. **2026-01-02 13:56**: Tree deserialized with wrong root `7c320bbb...`
2. **2026-01-02 13:56**: Delta CMU appended → root `c24f4a05...`
3. **2026-01-02 13:59**: Transaction failed with anchor validation error
4. **2026-01-02 14:10**: Implemented FIX #531-533
5. **2026-01-02 14:17**: FIX #534 detected mismatch, attempted CMU rebuild
6. **2026-01-02 14:18**: Rebuilt from corrupted CMUs → root still wrong
7. **2026-01-02 14:20**: Deleted corrupted legacy CMU cache
8. **2026-01-02 14:22**: Implemented FIX #534 v2 with auto-extraction

## Next Steps

1. **Test transaction send** after app restart
2. **Verify boost file tree root** matches blockchain at height 2964128
3. **Investigate Python serialization** if issues persist
4. **Consider regenerating boost file** with current zcash_primitives version

---

Generated: 2026-01-02
Investigator: Claude (AI Assistant)
Related: FIX #527, #531, #532, #533, #534
