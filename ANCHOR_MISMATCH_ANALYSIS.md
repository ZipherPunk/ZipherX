# Anchor Mismatch Analysis

## The Core Problem

Your ZipherX app is building transactions with an **incorrect anchor** (tree root). When zcashd validates the transaction, it rejects it because the anchor doesn't match any known tree state in the blockchain.

## Evidence

### Transaction Details
- **Transaction ID**: `d311f27b042cb2915c29dd380ea1154f4d887d66f940d8c3ed4f579ce3e9595e`
- **Block height at transaction time**: 2,921,892
- **Tree used**: OLD bundled tree with 1,041,539 CMUs (NOT the new 1,010,111 tree)

### Anchor Comparison

**Our app computed anchor:**
```
c148d1fcce8c42e28fe33651c5c2bad003c1b5c2e35d9642e1f92f57db779640
```

**zcashd's anchor at block 2,921,892:**
```
4d903297b7beac7cf4da5469448a2795c03a10cd21c83449a2f6e1376d86292e
```

**Result**: ❌ **MISMATCH** - The anchors are completely different!

## Root Cause

The app is loading a **cached/stale version** of the commitment tree file:

From z.log:
```
🌳 Loading bundled CMUs (31 MB)...
🌳 Building tree from 1041539 bundled CMUs...
🌳 Built commitment tree with 1041539 commitments in 53.6s
```

The source file `/Users/chris/ZipherX/Resources/commitment_tree_complete.bin` contains the correct 1,010,111 CMUs, but the app bundle has an old cached version.

## Why This Happens

1. **Xcode caches resources** - When you rebuild, Xcode may use cached versions of bundled resources
2. **DerivedData contains stale builds** - Old compiled app bundles with old tree files
3. **App bundle not updated** - The simulator continues using an old app bundle

## Solution Steps

### 1. Verify Source Tree File
```bash
cd /Users/chris/ZipherX

# Check file size (should be 31 MB)
ls -lh Resources/commitment_tree_complete.bin

# Check CMU count (should be 1,010,111)
python3 -c "
import struct
with open('Resources/commitment_tree_complete.bin', 'rb') as f:
    count = struct.unpack('<Q', f.read(8))[0]
    print(f'CMUs: {count:,}')
"
```

Expected output:
```
-rw-r--r--  1 chris  staff    31M Nov 25 12:16 Resources/commitment_tree_complete.bin
CMUs: 1,010,111
```

### 2. Clean All Build Caches
```bash
# Remove DerivedData
rm -rf ~/Library/Developer/Xcode/DerivedData/ZipherX-*

# Clean in Xcode
# Product → Clean Build Folder (Cmd+Shift+K)

# Delete app from simulator
# Simulator → Device → Erase All Content and Settings
```

### 3. Rebuild the App
Open Xcode and do a full rebuild:
```
Product → Clean Build Folder (Cmd+Shift+K)
Product → Build (Cmd+B)
Product → Run (Cmd+R)
```

### 4. Verify Bundled Tree
```bash
./Tools/check_app_bundle.sh
```

Expected output:
```
✅ Bundled tree matches source tree
📊 Bundled tree CMU count: 1,010,111
```

### 5. Check App Logs
After rebuilding, launch the app and check the logs. You should see:
```
🌳 Building tree from 1010111 bundled CMUs...
```

**NOT** this (indicates still using old tree):
```
🌳 Building tree from 1041539 bundled CMUs...
```

### 6. Test Transaction Again
After confirming the correct tree is loaded:
1. Import your key
2. Wait for balance to appear
3. Send a test transaction
4. Check if it's accepted by zcashd

## Next Steps After Rebuild

Once the app loads the correct tree (1,010,111 CMUs), we need to verify if the transaction succeeds or if there's still an anchor mismatch.

### If Transaction Still Fails

If the transaction is still rejected even with the correct tree, it means there's a **tree building algorithm mismatch** between:
- Our Rust FFI implementation (`librustzcash`)
- zcashd's internal Merkle tree implementation

This would require:
1. Comparing tree roots at intermediate points (e.g., every 10,000 CMUs)
2. Finding exactly where the tree computation diverges
3. Investigating the Rust tree implementation in ZipherXFFI
4. Potentially porting zcashd's exact tree algorithm

### Why This Is Hard

Mobile Zcash wallets typically use **lightwalletd** servers precisely because:
- Building correct witnesses requires exact tree state synchronization
- Even with identical CMUs in identical order, different hashing algorithms produce different roots
- The tree must match zcashd's internal state EXACTLY for proofs to verify

Your requirement to avoid lightwalletd/RPC and use pure P2P makes this significantly more challenging.

## Verification Tools

Use these tools to diagnose the issue:

1. **`check_app_bundle.sh`** - Verify which tree is bundled
2. **`verify_anchor.py <height>`** - Check zcashd's anchor at a height
3. **`compare_trees.py <tree1> <tree2>`** - Compare two tree files
4. **`parse_tx_anchor.py <raw_tx_hex>`** - Extract anchor from transaction

## Current Status

🚨 **BLOCKED**: App is using old cached tree with wrong anchor

✅ **READY**: New complete tree exported (1,010,111 CMUs from Sapling activation)

⏳ **NEXT**: Rebuild app to bundle correct tree, then test if transaction succeeds

## Historical Context

### Tree Export History

1. **Original bundled tree**: 1,041,539 CMUs (unknown provenance)
2. **First attempt**: Added 59 recent CMUs → 1,041,598 CMUs (still wrong)
3. **Second attempt**: Exported complete tree from zcashd → 1,010,111 CMUs (correct)

The discrepancy (1,041,539 vs 1,010,111) suggests the original tree may have included:
- Duplicate entries
- Non-Sapling outputs
- Or was exported from a different chain state

### Transaction Attempts

1. **First transaction**: `805ac803dc528e7e12c5da63554d644ce0daae6052279adbd64e7b3ca2ce36c0` - Rejected
2. **Second transaction**: `d311f27b042cb2915c29dd380ea1154f4d887d66f940d8c3ed4f579ce3e9595e` - Rejected (analyzed in this document)

Both used the wrong tree (1,041,539 CMUs) and had mismatched anchors.

## References

- [Zcash Protocol Spec - Section 4.12: Merkle Tree](https://zips.z.cash/protocol/protocol.pdf)
- [ZIP-221: FlyClient - Consensus-Layer Changes](https://zips.z.cash/zip-0221)
- [librustzcash documentation](https://docs.rs/librustzcash/latest/librustzcash/)

---

**Bottom Line**: The app must be rebuilt with the correct tree file. Only then can we determine if the tree building algorithm itself is correct.
