# ZipherX Project Instructions

## Quick Reference

| Document | Content |
|----------|---------|
| [docs/ARCHITECTURE.md](./docs/ARCHITECTURE.md) | System architecture, components, data flow |
| [docs/SECURITY.md](./docs/SECURITY.md) | Security requirements, encryption, audit |
| [docs/BUG_FIXES.md](./docs/BUG_FIXES.md) | All numbered fixes (FIX #1-156+) |
| [docs/WORKFLOW.md](./docs/WORKFLOW.md) | Build, debug, git workflow |
| [docs/CHECKPOINT_ANALYSIS.md](./docs/CHECKPOINT_ANALYSIS.md) | Checkpoint system: when verified/written |
| [CLAUDE_FULL_BACKUP.md](./CLAUDE_FULL_BACKUP.md) | Complete backup (if needed) |

## Project Overview

ZipherX is a secure, decentralized cryptocurrency wallet for iOS/macOS based on Zclassic/Zcash technology. Full-node-level security without requiring a full node.

## CRITICAL Requirements

### NEVER Do These
- **NEVER** kill any processes from Claude - **CRASHES THE APP**
- **NEVER** estimate dates or timelines
- **NEVER** change passwords without authorization
- **NEVER** run `kill` commands
- **NEVER** store unencrypted private keys
- **NEVER** trust a single network peer
- **NEVER** skip proof verification

### ALWAYS Do These
- **ALWAYS** use Secure Enclave for spending key operations
- **ALWAYS** require multi-peer consensus (threshold = 5)
- **ALWAYS** verify Sapling proofs locally
- **ALWAYS** encrypt sensitive database fields

## Debug Logs

```bash
# iOS Simulator log
/Users/chris/ZipherX/z.log

# macOS log
/Users/chris/ZipherX/zmac.log
```

## Key Files

| File | Purpose |
|------|---------|
| `Sources/App/ContentView.swift` | Main UI, FAST/FULL START logic |
| `Sources/Core/Wallet/WalletManager.swift` | Wallet operations, sync, repair |
| `Sources/Core/Network/NetworkManager.swift` | P2P connections, broadcast |
| `Sources/Core/Network/FilterScanner.swift` | Block scanning, note discovery |
| `Sources/Core/Crypto/TransactionBuilder.swift` | TX building, witness handling |
| `Sources/Core/Network/HeaderSyncManager.swift` | Header sync, timestamps |
| `Sources/Core/Network/TorManager.swift` | Embedded Tor (Arti) |
| `Libraries/zipherx-ffi/src/lib.rs` | Rust FFI functions |

## Current Constants

| Constant | Value |
|----------|-------|
| Bundled Tree Height | 2,926,122 |
| Bundled CMU Count | 1,041,891 |
| Sapling Activation | 476,969 |
| Consensus Threshold | 5 peers |
| Default Fee | 10,000 zatoshis |

## Common Issues & Fixes

| Issue | Solution |
|-------|----------|
| Stuck at X% sync | Check z.log for "Invalid magic bytes" or timeouts |
| Wrong balance | Settings → Repair Database |
| Wrong dates | Settings → Clear Block Headers |
| TX fails | Check anchor/witness match, branch ID |
| No peers | Wait 30s, check Tor mode status |

## FIX Numbering

All bug fixes are numbered: `FIX #N`. See [docs/BUG_FIXES.md](./docs/BUG_FIXES.md) for complete list.

Latest fixes:
- FIX #157: Header sync timeout (20s per-peer, 60s total) for FAST START
- FIX #158: Filter banned peers from TX broadcast (Sybil protection)
- FIX #159: Permanent Sybil bans - indefinite until manual unban
- FIX #162 v3: Balance Reconciliation AUTO-REPAIR at startup
  - Created `getAllNotes()` function that returns ALL notes (spent + unspent)
  - Previous `getAllUnspentNotes()` was misleading - had `WHERE is_spent = 0`
  - `rebuildHistoryFromUnspentNotes()` now uses `getAllNotes()` for RECEIVED
  - Correct formula: RECEIVED (all notes) - SENT - FEES = UNSPENT balance
  - Groups spent notes by `spent_in_tx`, calculates sent = inputs - change - fee
  - Views check `isRepairingHistory` flag to prevent undoing repair
- FIX #164: Nullifier verification health check at startup
  - Scans recent blocks to verify unspent notes haven't been spent on-chain
  - Detects missed spending transactions (e.g., from other wallet instances)
  - Marks spent notes and updates balance if nullifiers found on blockchain
- FIX #164 v2: Use checkpoint-based scanning when checkpoint exists
  - If checkpoint exists: Scans checkpoint+1 → current (FAST - typically 0-10 blocks)
  - If no checkpoint: Falls back to oldest note height (accurate for imports)
  - MUCH faster for FAST START where checkpoint is always set
  - Previous bug: ALWAYS scanned from oldest note (13,000+ blocks), 8+ minute hangs
- FIX #165: Checkpoint-based startup sync for ALL missed transactions
  - Added `verified_checkpoint_height` column to `sync_state` table (Migration 7)
  - Health check 12: Scans from checkpoint to chain tip at every startup
  - Detects BOTH incoming notes (trial decryption) AND spent notes (nullifiers)
- FIX #165 v2: Checkpoint only updated on TX CONFIRMATION, not mempool
  - REMOVED checkpoint update from `sendShieldedWithProgress()` and `sendShielded()`
  - ADDED checkpoint update to `confirmOutgoingTx()` (when sent TX is mined)
  - ADDED checkpoint update to `confirmIncomingTx()` (when received TX is mined)
  - Fixes edge case: if user sends from another wallet before TX confirms,
    the other transaction would be missed because checkpoint was set too early
  - Ensures wallet ALWAYS discovers new ZCL sent while app was closed
- FIX #120 (v2): FAST START must connect to P2P network before health checks
  - Previous bug: Fast path skipped network connection when no header sync needed
  - FIX #164/165 health checks need chain height from P2P peers
  - Health checks ran with chain height = 0, causing checkpoint sync to be skipped
  - Now: Even in fast path, connect to 3+ peers BEFORE running health checks
  - Ensures checkpoint-based sync ALWAYS runs to detect missed transactions
- FIX #166: Corrupted `last_scanned_height` detection and auto-fix at startup
  - New health check (runs FIRST) detects impossible block heights (>3.5M or >1000 ahead of trusted)
  - Compares against: HeaderStore height, cached chain height, checkpoint height
  - Auto-fixes by resetting to checkpoint height (last verified good state)
  - Added validation to `updateLastScannedHeight()` to block writes >100k blocks ahead
  - Stack trace logging captures source of any future corruption attempts
  - Prevents balance issues caused by sync state pointing to impossible future blocks
- FIX #169: Transaction history "sent" amount was including fee (wrong display)
  - Bug: `populateHistoryFromNotes()` stored `totalBalanceImpact` (input - change = recipient + fee)
  - Fix: Now stores `amountToRecipient` (input - change - fee = actual sent to recipient)
  - Fee is stored separately in the `fee` column and displayed separately in UI
  - Run "Repair Database" to regenerate history with correct sent amounts
- FIX #174: Disable SEND when unconfirmed transaction in mempool (app or external wallet)
  - Detects external wallet spends by parsing nullifiers from mempool transactions
  - If nullifier matches an unspent note AND tx is NOT our pending outgoing → external spend!
  - Added `parseShieldedSpends()` to extract nullifiers from Sapling v4 transactions
  - Added `getNoteByNullifier()` to WalletDatabase (uses VUL-009 nullifier hashing)
  - Published properties: `hasPendingMempoolTransaction`, `pendingTransactionReason`, `externalWalletSpendDetected`
  - SendView: Shows reason why SEND is disabled, uses warning icon for external spends
  - NotificationManager: `notifyExternalWalletSpend()` sends critical alert notification
  - External spends tracked like our own pending outgoing (confirmation clears flags)
- FIX #175: Notify user when Sybil attack detected or Tor bypassed
  - UI alert in ContentView shows when `sybilVersionAttackAlert` is set
  - Alert explains: number of attackers, whether Tor was bypassed, user's funds are safe
  - Cypherpunk manifesto quote included in alert message
  - External wallet spend alert shows amount, txid, and security warning
  - Both alerts watch for property changes via `.onChange()` modifiers
- FIX #176: Update checkpoint after database repair operations
  - `repairNotesAfterDownloadedTree()` now updates `verified_checkpoint_height` after:
    1. Quick fix (anchor extraction from existing witnesses)
    2. Full rescan (complete blockchain rescan)
  - Also added to `backgroundSyncToHeight()` after successful sync
  - Prevents "Checkpoint Sync" health check from failing immediately after repair
  - Checkpoint is set to `lastScannedHeight` ensuring alignment with scan state
- FIX #177: Handle "Checkpoint Sync" health check failures at startup
  - Previous bug: Health check detected checkpoint mismatch but had NO repair handler
  - ContentView now includes `hasCheckpointIssues` in repair trigger condition
  - When "Checkpoint Sync" issue detected → triggers `repairNotesAfterDownloadedTree()`
  - FIX #176 then updates checkpoint, preventing immediate re-failure on verification
- FIX #178: CRITICAL - PHASE 1 scan skipped + unnecessary boost download
  - **Bug 1**: `scanWithinDownloadedRange` not set when `lastScanned > 0`
    - FilterScanner.swift line 233-234: When `lastScanned > 0`, code set `startHeight = lastScanned + 1`
    - BUT did NOT set `scanWithinDownloadedRange = true`
    - PHASE 1 condition at line 490: `if scanWithinDownloadedRange && startHeight <= phase1EndHeight`
    - Result: PHASE 1 ALWAYS skipped for consecutive startups, notes not discovered!
    - Fix: Added check `if startHeight <= effectiveTreeHeight && hasDownloadedTree` to set flag
  - **Bug 2**: Boost file downloaded even when cached version is current
    - CommitmentTreeUpdater.swift `getBestAvailableBoostFile()` only checked if cached file exists
    - Did NOT compare cached vs remote version heights before downloading
    - Result: Boost file unnecessarily re-downloaded on every startup
    - Fix: Now fetches remote manifest and compares `chain_height` - only downloads if remote > cached
  - Files Modified:
    - `Sources/Core/Network/FilterScanner.swift` - Set `scanWithinDownloadedRange` when `lastScanned > 0`
    - `Sources/Core/Services/CommitmentTreeUpdater.swift` - Compare versions before downloading
- FIX #180: Limit header sync to 100 blocks maximum for speed
  - **Problem**: Header sync trying to sync 2609 blocks when 100 is enough for consensus
  - **Root Cause**: `syncHeaders()` took `startHeight` but synced ALL the way to chain tip
  - **Solution**: Added `maxHeaders` parameter to `syncHeaders()` function
    - HeaderSyncManager.swift: Added `maxHeaders: UInt64? = nil` parameter
    - Limits `chainTip` to `startHeight + maxHeaders` when specified
  - **Callers Updated**:
    - WalletManager.swift line 934: `syncHeaders(from: earliestNeedingTimestamp, maxHeaders: 100)`
    - WalletManager.swift line 1102: `syncHeaders(from: earliestNeedingTimestamp, maxHeaders: 100)`
    - WalletManager.swift line 1113: `syncHeaders(from: currentHeight + 1, maxHeaders: 100)`
    - WalletManager.swift line 1820: `syncHeaders(from: startHeight, maxHeaders: 100)`
  - **Result**: 100 blocks is enough for peer consensus verification - much faster sync
- FIX #169: Persistent .onion Address with Keypair Storage
  - **Feature**: Same .onion address persists across app restarts
  - **Architecture**:
    - Ed25519 keypair stored in iOS Keychain (macOS Keychain on macOS)
    - 64-byte format: 32-byte secret + 32-byte public key
    - Keypair generated once on first Tor start, reused thereafter
  - **Rust FFI** (`tor.rs`):
    - `zipherx_start_tor_with_keypair(keypair_ptr, keypair_len)` - Start with existing keypair
    - Uses `tor_llcrypto::pk::ed25519::{Keypair, ExpandedKeypair}`
    - Type chain: `[u8;32]` → `TorKeypair::from_bytes()` → `ExpandedKeypair::from()` → `HsIdKeypair::from()`
    - Requires `experimental-api` feature on `arti-client` for `launch_onion_service_with_hsid()`
  - **Swift Integration** (`TorManager.swift`):
    - `generateAndStoreKeypair()` - Generate new Ed25519 keypair, store in Keychain
    - `loadStoredKeypair()` - Load existing keypair from Keychain
    - `startArtiWithKeypair()` - Start Tor with persistent identity
    - Keychain keys: `"ZipherX-Onion-Keypair"`, `"ZipherX-Onion-Address"`
  - **Files Modified**:
    - `Libraries/zipherx-ffi/Cargo.toml` - Added `tor-llcrypto = "0.37"`, `experimental-api` feature
    - `Libraries/zipherx-ffi/src/tor.rs` - Persistent keypair hidden service startup
    - `Sources/Core/Network/TorManager.swift` - Keypair generation and Keychain storage
    - `Sources/ZipherX-Bridging-Header.h` - FFI function declarations

## Security Score: 100/100

All 28 vulnerabilities fixed. See [docs/SECURITY.md](./docs/SECURITY.md).
