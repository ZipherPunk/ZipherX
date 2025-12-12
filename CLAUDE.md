# ZipherX Project Instructions

## Quick Reference

| Document | Content |
|----------|---------|
| [docs/ARCHITECTURE.md](./docs/ARCHITECTURE.md) | System architecture, components, data flow |
| [docs/SECURITY.md](./docs/SECURITY.md) | Security requirements, encryption, audit |
| [docs/BUG_FIXES.md](./docs/BUG_FIXES.md) | All numbered fixes (FIX #1-156+) |
| [docs/WORKFLOW.md](./docs/WORKFLOW.md) | Build, debug, git workflow |
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
- FIX #165: Checkpoint-based startup sync for ALL missed transactions
  - Added `verified_checkpoint_height` column to `sync_state` table (Migration 7)
  - Health check 12: Scans from checkpoint to chain tip at every startup
  - Detects BOTH incoming notes (trial decryption) AND spent notes (nullifiers)
  - Checkpoint updated after: startup scan, send TX success, incoming TX confirmed
  - Ensures wallet ALWAYS discovers new ZCL sent while app was closed
- FIX #120 (v2): FAST START must connect to P2P network before health checks
  - Previous bug: Fast path skipped network connection when no header sync needed
  - FIX #164/165 health checks need chain height from P2P peers
  - Health checks ran with chain height = 0, causing checkpoint sync to be skipped
  - Now: Even in fast path, connect to 3+ peers BEFORE running health checks
  - Ensures checkpoint-based sync ALWAYS runs to detect missed transactions

## Security Score: 100/100

All 28 vulnerabilities fixed. See [docs/SECURITY.md](./docs/SECURITY.md).
