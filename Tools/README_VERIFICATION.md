# Verification Tools

These tools help verify that the bundled commitment tree is correct and matches zcashd's state.

## Tools Overview

### 1. `check_app_bundle.sh` - Check what tree is bundled in the app
**Purpose**: Verify which version of the tree file is actually bundled in the compiled app

**Usage**:
```bash
./Tools/check_app_bundle.sh
```

**What it checks**:
- Finds the ZipherX.app bundle in the iOS Simulator
- Extracts the CMU count from the bundled tree file
- Compares with the source tree file in `/Resources/`
- Shows if they match

**Expected output after correct rebuild**:
```
✅ Bundled tree matches source tree
📊 Bundled tree CMU count: 1,010,111
```

---

### 2. `verify_anchor.py` - Check zcashd's anchor at a specific block
**Purpose**: Query zcashd to see what the Sapling tree root (anchor) should be at a given block height

**Usage**:
```bash
python3 Tools/verify_anchor.py <block_height>

# Example: Check anchor at block 2921565 (bundled tree height)
python3 Tools/verify_anchor.py 2921565
```

**What it shows**:
- The `finalsaplingroot` from zcashd at that block
- This is the anchor our app should compute if the tree is correct

**Example output**:
```
🌳 zcashd's Sapling root at height 2,921,565:
   641c4d8d74f8e9f098de074ef6cb32a27b66f4bb09917663e61fbc234aeb9b87
```

---

### 3. `compare_trees.py` - Compare two tree files
**Purpose**: Compare CMUs between two tree export files to find differences

**Usage**:
```bash
python3 Tools/compare_trees.py <tree1.bin> <tree2.bin>

# Example: Compare old and new trees
python3 Tools/compare_trees.py old_tree.bin Resources/commitment_tree_complete.bin
```

**What it shows**:
- CMU counts in each file
- First difference index (if any)
- Sample comparison of first and last 5 CMUs
- Whether trees are identical

---

## Verification Workflow

### Step 1: Verify the source tree file is correct
```bash
ls -lh Resources/commitment_tree_complete.bin
# Should show: 31M

python3 -c "
import struct
with open('Resources/commitment_tree_complete.bin', 'rb') as f:
    count = struct.unpack('<Q', f.read(8))[0]
    print(f'CMUs: {count:,}')
"
# Should show: CMUs: 1,010,111
```

### Step 2: Clean build cache
```bash
rm -rf ~/Library/Developer/Xcode/DerivedData/ZipherX-*
```

### Step 3: Rebuild the app
Open Xcode and build the project (or use xcodebuild command)

### Step 4: Check the bundled tree
```bash
./Tools/check_app_bundle.sh
```

Should show:
```
✅ Bundled tree matches source tree
📊 Bundled tree CMU count: 1,010,111
```

### Step 5: Run the app and check logs
Look for this in the app logs:
```
🌳 Building tree from 1010111 bundled CMUs...
```

**NOT** this (old tree):
```
🌳 Building tree from 1041539 bundled CMUs...
```

### Step 6: After sending a transaction, check the anchor
From the app logs, note the anchor being used:
```
📝 Using current tree root as anchor: c148d1fcce8c42e2...
```

Then verify against zcashd at the current block height:
```bash
# Get current height
zclassic-cli getblockchaininfo | grep blocks

# Check anchor at that height
python3 Tools/verify_anchor.py <height>
```

The anchor from the app should match zcashd's `finalsaplingroot`.

---

## Common Issues

### Issue: App still loads old tree after rebuild

**Symptom**: App logs show `1041539` CMUs instead of `1010111`

**Solution**:
1. Clean build completely: `rm -rf ~/Library/Developer/Xcode/DerivedData/ZipherX-*`
2. Clean in Xcode: Product → Clean Build Folder (Cmd+Shift+K)
3. Delete app from simulator
4. Rebuild

### Issue: Transaction rejected with "Sapling spend description invalid"

**Possible causes**:
1. **Wrong tree loaded** - Check with `check_app_bundle.sh`
2. **Anchor mismatch** - Our tree root doesn't match zcashd's `finalsaplingroot`
3. **Tree building algorithm difference** - Even with correct CMUs, our Rust implementation may compute different tree roots than zcashd

**Debug steps**:
1. Verify correct tree is loaded (1,010,111 CMUs)
2. Extract anchor from app logs after transaction attempt
3. Compare with zcashd's anchor at same height using `verify_anchor.py`
4. If they don't match, there's a tree algorithm incompatibility

---

## Tree Export Files

### Current Files

**`Resources/commitment_tree_complete.bin`** (31 MB, 1,010,111 CMUs)
- Complete tree from Sapling activation (block 476,969) to block 2,921,695
- Exported directly from zcashd using `export_tree_parallel.py`
- This is the file that should be bundled in the app

### How the tree was exported

```bash
# Took 2.91 hours to export with 20 parallel workers
python3 Tools/export_tree_parallel.py
```

This scanned all blocks from 476,969 (Sapling activation) to current height, extracting every `vShieldedOutput` CMU from every transaction.

---

## Expected Values

| Property | Value |
|----------|-------|
| Tree file size | 31 MB |
| CMU count | 1,010,111 |
| Sapling activation height | 476,969 |
| Tree export end height | 2,921,695 |
| Anchor at block 2,921,565 | `641c4d8d74f8e9f098de074ef6cb32a27b66f4bb09917663e61fbc234aeb9b87` |

---

## Next Steps If Transaction Still Fails

If the transaction is still rejected even with the correct tree (1,010,111 CMUs), the issue is likely a **tree building algorithm mismatch** between our Rust implementation and zcashd.

Possible approaches:
1. **Compare tree roots at intermediate points** - Build trees with different numbers of CMUs and compare roots with zcashd
2. **Examine the Rust tree implementation** - Review how `librustzcash` builds Merkle trees
3. **Use lightwalletd** - This is the standard solution for mobile wallets (but user rejected this)
4. **Implement zcashd's exact tree algorithm** - Port zcashd's incremental Merkle tree to our codebase

The fundamental challenge: Mobile Zcash wallets typically rely on lightwalletd servers precisely because building transactions with correct anchors requires exact tree state synchronization with zcashd's internal implementation.
