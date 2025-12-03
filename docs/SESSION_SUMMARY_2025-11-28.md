# Session Summary - November 28, 2025

## Overview

This session focused on optimizing the TransactionBuilder for faster send transactions. Multiple approaches were attempted but all failed due to **witness/anchor consistency issues**. The code was ultimately restored to the working state from commit `987faaa`.

## Problem Statement

Transaction building was slow because:
1. Full bundled tree (1M+ CMUs) was reloaded for notes beyond bundled height
2. Tree rebuild took ~54 seconds
3. New blocks could arrive during rebuild, causing race conditions
4. P2P fetching and InsightAPI had timeout issues

## Optimization Attempts

### Attempt 1: Use In-Memory Tree
- **Idea**: Check if `WalletManager.shared.isTreeLoaded` and use existing tree state via `getTreeSerializedData()`
- **Result**: Failed - computed anchor didn't match header store anchor

### Attempt 2: P2P Batch Fetch Optimization
- **Changes**:
  - Limited batch size to 50 blocks
  - Added 30-second timeout to `getFullBlocks()`
  - Added `withTimeout()` helper function
  - Added `p2pFetchFailed` flag to prevent infinite retry loops
- **Result**: Reduced loops but didn't fix anchor mismatch

### Attempt 3: InsightAPI Rate Limiting
- **Changes**:
  - Added parallel batch fetching
  - Added 30-second timeout
  - Fallback from P2P to InsightAPI with retry limits
- **Result**: Improved reliability but didn't fix anchor mismatch

### Attempt 4: Always Use Computed Anchor
- **Idea**: If header store anchor doesn't match rebuilt tree, use computed anchor
- **Result**: Still failed - error code 18 (REJECT_INVALID)

### Attempt 5: Progress Bar Fix
- **Problem**: Progress bar showed 100% during initial sync
- **Fix**: Added `isInitialSync` to cap condition
- **Result**: Worked, but unrelated to main issue

## Root Cause Analysis

The transaction was rejected with error code 18:
```
Header store anchor: ae6f5305aad161f31204e43701fdd35e...
Computed anchor:     0b0b15e40e80b035...
```

The **witness** and **anchor** must come from the same tree state. My optimizations broke this invariant:
- Witness was from rebuilt tree (current state)
- Anchor was from header store (historical state at note height)
- These didn't match, so spend proof was invalid

## Why Original Code Works

The working version (`987faaa`) uses:
1. **Anchor from header store** - contains canonical `finalSaplingRoot` from blockchain
2. **Rebuilt witness** - computed by loading bundled CMUs + additional CMUs

This works because:
- The witness path is valid for the note's position in any tree containing that note
- The anchor from header store is what zcashd expects for that block height
- Even if tree timing differs slightly, the anchor is canonical

## Resolution

1. Stashed all changes: `git stash`
2. Restored TransactionBuilder.swift: `git checkout 987faaa -- Sources/Core/Crypto/TransactionBuilder.swift`
3. Updated CLAUDE.md with documentation
4. Committed and pushed

## Files Modified

| File | Change |
|------|--------|
| `Sources/Core/Crypto/TransactionBuilder.swift` | Restored to `987faaa` |
| `CLAUDE.md` | Added section 14 documenting this session |
| `Sources/Core/Network/Peer.swift` | Stashed (P2P timeout improvements) |
| `Sources/App/ContentView.swift` | Stashed (progress bar fix) |

## Key Lessons Learned

1. **Anchor MUST come from header store** - not from computed tree state
2. **Witness can be rebuilt** - as long as tree contains the note
3. **Don't optimize what isn't broken** - the original code worked correctly
4. **Test thoroughly before committing** - especially cryptographic code

## Future Optimization Ideas

If transaction building speed becomes a priority:
1. Pre-cache witnesses for known notes during sync
2. Store witness alongside note when appending to tree
3. Background tree update worker that doesn't block send
4. Keep tree in sync and only fetch missing CMUs incrementally

## Git History

```
94ee659 Revert TransactionBuilder optimizations that broke anchor/witness consistency
e9073ff Add peer persistence, P2P tx parsing, and catch-up sync
987faaa [Last known working state]
```

## Stashed Changes

The following changes were stashed and may be useful later:
- P2P timeout improvements in `Peer.swift`
- Progress bar fix in `ContentView.swift`

To recover: `git stash pop` (but test carefully!)
