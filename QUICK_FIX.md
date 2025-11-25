# Quick Fix Guide

## Problem
Your app is using an **OLD CACHED tree** with the wrong anchor, causing all transactions to be rejected.

## The Fix (Run These Commands)

```bash
# 1. Verify source tree is correct
cd /Users/chris/ZipherX
python3 -c "import struct; f=open('Resources/commitment_tree_complete.bin','rb'); count=struct.unpack('<Q',f.read(8))[0]; print(f'CMUs: {count:,}')"
# Should show: CMUs: 1,010,111

# 2. Clean all build caches
rm -rf ~/Library/Developer/Xcode/DerivedData/ZipherX-*

# 3. Then rebuild in Xcode:
#    - Product → Clean Build Folder (Cmd+Shift+K)
#    - Product → Build (Cmd+B)
#    - Product → Run (Cmd+R)

# 4. Verify the bundled tree
./Tools/check_app_bundle.sh
# Should show: Bundled tree CMU count: 1,010,111

# 5. Check app logs after launch
#    Look for: "🌳 Building tree from 1010111 bundled CMUs..."
#    NOT: "🌳 Building tree from 1041539 bundled CMUs..."
```

## What's Wrong

**Your app computed this anchor:**
```
c148d1fcce8c42e28fe33651c5c2bad003c1b5c2e35d9642e1f92f57db779640
```

**zcashd expected this anchor:**
```
4d903297b7beac7cf4da5469448a2795c03a10cd21c83449a2f6e1376d86292e
```

They don't match because the app loaded an old tree with 1,041,539 CMUs instead of the correct 1,010,111 CMUs.

## After Rebuild

1. Launch app and import key
2. Wait for balance
3. Send test transaction
4. Check if accepted

If still rejected, we need to investigate the tree building algorithm in the Rust FFI.

## Tools Available

- `./Tools/check_app_bundle.sh` - Check what's bundled
- `python3 Tools/verify_anchor.py 2921892` - Check zcashd's anchor
- See `Tools/README_VERIFICATION.md` for more

## Full Details

See `ANCHOR_MISMATCH_ANALYSIS.md` for complete analysis.
