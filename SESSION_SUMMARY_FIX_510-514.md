# Session Fixes Summary - FIX #510-514

## Date: December 31, 2025

## Overview
Fixed multiple issues related to transaction building, UI refresh, and CMU lookup failures.

---

## FIX #510: Import Complete - UI Refresh

**Problem**: After import PK, transaction history wasn't displayed until app restart.

**Root Cause**: `markImportComplete()` didn't trigger UI refresh.

**Solution**:
- Increment `transactionHistoryVersion`
- Post `transactionHistoryUpdated` notification

**File**: `Sources/Core/Wallet/WalletManager.swift:5310-5324`

```swift
func markImportComplete() {
    self.isImportInProgress = false
    print("✅ FIX #500: Import sync completed")

    // FIX #510: Trigger UI refresh for transaction history
    self.transactionHistoryVersion += 1
    NotificationCenter.default.post(name: Notification.Name("transactionHistoryUpdated"), object: nil)
}
```

---

## FIX #479 v2: Tree Root Validation False Warning

**Problem**: "Tree root has 40 extra CMUs from PHASE 2" warning shown even though this is expected (new notes found during scanning).

**Root Cause**: When PHASE 2 discovers new notes beyond the boost file, the tree has extra CMUs - this is CORRECT!

**Solution**: Changed to return `.passed()` with positive message "PHASE 2 discovered X new notes beyond boost file".

**File**: `Sources/Core/Wallet/WalletHealthCheck.swift:717-727`

---

## FIX #511: Block Listener Race Condition During TX Build

**Problem**: Block listeners consume P2P responses (like "headers") that TX build needs for CMU fetching/witness rebuilding.

**User Request**: "stop blocklistener when the app start to build txn ! and restart it when txn is sent and accepted by peer and mempool !"

**Solution**:
- Stop all block listeners at START of `sendShielded` and `sendShieldedWithProgress`
- Restart them AFTER TX is accepted by peers/mempool

**Files Modified**:
- `Sources/Core/Wallet/WalletManager.swift:4371-4373` (sendShieldedWithProgress start)
- `Sources/Core/Wallet/WalletManager.swift:4591-4592` (sendShielded start)
- `Sources/Core/Wallet/WalletManager.swift:4577-4579` (sendShieldedWithProgress end)
- `Sources/Core/Wallet/WalletManager.swift:4772-4773` (sendShielded end)

---

## FIX #513: CMU Diagnostic Logging

**Problem**: When CMU not found in bundled file, unclear if database CMU is wrong or bundled file is incomplete.

**Solution**: Added diagnostic check that fetches the specific block at note height to verify if CMU exists on-chain.

**File**: `Sources/Core/Crypto/TransactionBuilder.swift:943-971`

**Diagnostic Output**:
- "CMU VERIFIED at height 2954661" → database is correct, bundled file is incomplete
- "CMU NOT FOUND at height 2954661" → database CMU is wrong, run Full Rescan

---

## FIX #514: CMU Byte Order Mismatch ⭐ CRITICAL FIX

**Problem**: "Failed to generate zero-knowledge proof" - CMU `f11ad11f...` at height 2954661 was NOT in bundled CMU file (which should contain CMUs up to height 2962638).

**User Feedback**: "NOT possible it must be inside but the app is looking for it badly !!!"

**Root Cause**: The `treeCreateWitnessForCMU` function only checked CMU in one byte order, but the database might store CMUs in the opposite byte order compared to the bundled CMU file.

**Evidence**: Similar issue was already fixed in FIX #471 for `find_cmu_positions_batch`, but NOT in `treeCreateWitnessForCMU`!

**Solution**:
1. Check BOTH original AND reversed byte orders when searching for CMU in bundled file
2. Apply same fix to P2P CMU search in `rebuildWitnessForNote`

**Files Modified**:
- `/Users/chris/ZipherX/Libraries/zipherx-ffi/src/lib.rs:3302-3339`
- `Sources/Core/Crypto/TransactionBuilder.swift:1342-1347`

**Rust Code** (lib.rs):
```rust
// FIX #471: Check both original AND reversed byte orders for target CMU
// The database might store CMUs in different byte order than boost file
let mut target_bytes_reversed = [0u8; 32];
for j in 0..32 {
    target_bytes_reversed[j] = target_bytes[31 - j];
}

// Find target CMU position (compare against wire format in file)
// FIX #514: Try both byte orders to handle potential mismatches
let mut target_pos: Option<u64> = None;
let mut offset = 8;
for i in 0..count {
    if &bytes[offset..offset + 32] == target_bytes {
        target_pos = Some(i);
        debug_log!("📍 Found target CMU at position {} (original byte order)", i);
        break;
    }
    // Also try reversed byte order
    if &bytes[offset..offset + 32] == target_bytes_reversed {
        target_pos = Some(i);
        debug_log!("📍 Found target CMU at position {} (REVERSED byte order - database has opposite order!)", i);
        break;
    }
    offset += 32;
}
```

**Swift Code** (TransactionBuilder.swift):
```swift
// FIX #514: Also create reversed version of target CMU for byte order comparison
let cmuReversed = Data(cmu.reversed())

for blockCMU in allDeltaCMUs {
    // Check if this is our note's CMU (try both byte orders)
    if blockCMU == cmu || blockCMU == cmuReversed {
        // Found our note! Append it and capture witness
        ...
    }
}
```

---

## CRITICAL DISCOVERY - Database CMU Corruption! ⚠️

**Date**: January 1, 2026 18:15

**Problem**: Transaction building failed with "Failed to generate zero-knowledge proof"

**Investigation**:
1. Enabled debug logging (set `DEBUG_LOGGING = true` in lib.rs)
2. Rebuilt FFI library with FIX #514 byte order checking
3. Log showed: "❌ FIX #514: Target CMU not found in bundled data (tried both byte orders)"
4. Searched boost file `legacy_cmus_v2.bin` for the target CMU

**Root Cause**: DATABASE HAS CORRUPTED CMU!

At height **2954661**:
- **Correct CMU in boost file**: `b390d9c414ec26a5641bfde16e86dd288a60da67477cbf377f8c6fb0f6eb3d64`
- **Wrong CMU in database**: `f11ad11fb03324c8a4d82c947d88333662473669f370601e6fcc700d5986dd54`

These are completely different! The database has a CMU that never existed on-chain.

**Required Fix**: FULL RESCAN
- Settings → Database Repair → Full Rescan (RED button)
- This will delete all corrupted notes and rescan entire blockchain
- The correct CMU will be found from on-chain data

**Impact**: This explains why transaction building fails - the app searches for a non-existent CMU!

---

## Testing

After FULL RESCAN completes, the transaction should build successfully with the correct CMU.

---

## Build Status

- Rust FFI: ✅ Built with FIX #514 + debug logging enabled
- Universal library: ✅ Built and updated xcframework
- App: ⏳ User needs to rebuild after database fix
