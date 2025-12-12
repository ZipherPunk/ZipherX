# ZipherX Transaction & Startup Sync Process

## Overview

This document describes how ZipherX handles transaction discovery, balance verification, and startup synchronization to ensure wallet state is always accurate.

## Checkpoint-Based Architecture (FIX #165)

### Problem Solved

When the app is closed, transactions can occur on the blockchain:
1. **Incoming**: Someone sends ZCL to your wallet
2. **Outgoing**: Another wallet instance spends your notes

Without proper detection, the wallet would show incorrect balance.

### Solution: Verified Checkpoint

A checkpoint is stored in the database (`sync_state.verified_checkpoint_height`) representing the last block height where wallet state was verified correct.

**Checkpoint is updated when:** (FIX #165 v2)
1. App startup scan completes successfully
2. Send transaction is **MINED** (confirmed in a block) - NOT at mempool acceptance
3. Incoming transaction is **MINED** (confirmed in a block)

**Why confirmation, not mempool?** (FIX #165 v2)
If checkpoint was updated at mempool acceptance, and user sends from another wallet
with the same private key before the TX confirms, that other transaction would be
missed because checkpoint would skip over the blocks where it occurred.

**On every app startup:**
- Scan from `checkpoint + 1` to `current chain tip`
- Check for spent notes (nullifier matching)
- Check for incoming notes (trial decryption)
- Update checkpoint after successful scan

## Startup Flow

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          APP STARTUP                                         │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
                    ┌───────────────────────────────┐
                    │   Connect to P2P Peers        │
                    │   (Wait for 3+ connections)   │
                    └───────────────────────────────┘
                                    │
                                    ▼
                    ┌───────────────────────────────┐
                    │   Get Current Chain Height    │
                    │   (P2P consensus)             │
                    └───────────────────────────────┘
                                    │
                                    ▼
              ┌─────────────────────────────────────────────┐
              │           FAST START CHECK                   │
              │  lastScannedHeight within 50 blocks of      │
              │  cachedChainHeight?                          │
              └─────────────────────────────────────────────┘
                         │                      │
                    YES  │                      │  NO
                         ▼                      ▼
        ┌────────────────────────┐    ┌────────────────────────┐
        │     FAST START         │    │     FULL START         │
        │                        │    │                        │
        │ 1. Load cached balance │    │ 1. Load commitment tree│
        │ 2. Run health checks   │    │ 2. Full block scan     │
        │ 3. Header sync (100)   │    │ 3. Build witnesses     │
        │ 4. Enable background   │    │ 4. Update balance      │
        └────────────────────────┘    └────────────────────────┘
                         │                      │
                         └──────────┬───────────┘
                                    │
                                    ▼
                    ┌───────────────────────────────┐
                    │      HEALTH CHECKS            │
                    │   (12 checks run at startup)  │
                    └───────────────────────────────┘
                                    │
                                    ▼
                    ┌───────────────────────────────┐
                    │   CHECKPOINT SYNC (FIX #165)  │
                    │                               │
                    │ Scan checkpoint → chain tip   │
                    │ - Trial decrypt for incoming  │
                    │ - Nullifier match for spent   │
                    └───────────────────────────────┘
                                    │
                                    ▼
                    ┌───────────────────────────────┐
                    │   UPDATE CHECKPOINT           │
                    │   (if scan successful)        │
                    └───────────────────────────────┘
                                    │
                                    ▼
                    ┌───────────────────────────────┐
                    │   ENABLE BACKGROUND PROCESSES │
                    │   - Mempool scan              │
                    │   - Stats refresh             │
                    └───────────────────────────────┘
                                    │
                                    ▼
                    ┌───────────────────────────────┐
                    │      MAIN WALLET UI           │
                    └───────────────────────────────┘
```

## Health Checks (12 Total)

| # | Check | Purpose |
|---|-------|---------|
| 1 | Bundle Files | Verify Sapling parameters exist |
| 2 | Database Integrity | Count notes, history, headers |
| 3 | Delta CMU | Verify tree size and root |
| 4 | Timestamps | All transactions have timestamps |
| 5 | Balance Reconciliation | Note balance matches history |
| 6 | Hash Accuracy | Verify block hashes with peers |
| 7 | P2P Connectivity | At least 3 peers connected |
| 8 | Equihash PoW | Verify last 100 block headers |
| 9 | Witness Validity | All notes have valid witnesses |
| 10 | Notes Integrity | All notes have required fields |
| 11 | **Nullifier Check (FIX #164)** | Verify unspent notes not spent on-chain |
| 12 | **Checkpoint Sync (FIX #165)** | Scan checkpoint→tip for ALL missed tx |

## Transaction Discovery Process

### Incoming Transactions

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    INCOMING TRANSACTION DETECTION                            │
└─────────────────────────────────────────────────────────────────────────────┘

1. MEMPOOL SCAN (while app running)
   - Scan mempool every 30 seconds
   - Trial decrypt each output with spending key
   - If decryption succeeds → our note!
   - Show notification / fireworks

2. CHECKPOINT SCAN (at startup)
   - Get blocks from checkpoint to chain tip
   - For each transaction output:
     - Trial decrypt with spending key
     - If succeeds → found incoming note
   - Log discovery, trigger full sync for witness

3. BLOCK LISTENER (real-time)
   - Listen for new block announcements
   - Scan new blocks for our transactions
```

### Spent Transaction Detection

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    SPENT TRANSACTION DETECTION                               │
└─────────────────────────────────────────────────────────────────────────────┘

1. NULLIFIER MATCHING
   - Each note has a unique nullifier
   - When spent, nullifier appears on blockchain
   - We compare our note nullifiers against blockchain spends

2. FIX #164 CHECK (at startup)
   - Get all unspent note nullifiers from database
   - Scan recent blocks (checkpoint to tip)
   - For each spend in each transaction:
     - Compare spend nullifier to our nullifiers
     - If match → note was spent!
   - Mark note as spent, update balance

3. DETECTION FLOW:
   ┌──────────────────┐
   │ Get unspent notes│
   │ from database    │
   └────────┬─────────┘
            │
            ▼
   ┌──────────────────┐
   │ Convert to       │
   │ display format   │
   │ (big-endian hex) │
   └────────┬─────────┘
            │
            ▼
   ┌──────────────────┐     ┌──────────────────┐
   │ For each block   │────▶│ For each spend   │
   │ in scan range    │     │ in transaction   │
   └──────────────────┘     └────────┬─────────┘
                                     │
                                     ▼
                            ┌──────────────────┐
                            │ Compare spend    │
                            │ nullifier to our │
                            │ note nullifiers  │
                            └────────┬─────────┘
                                     │
                            Match?   │
                         ┌───────────┴───────────┐
                         │ YES                   │ NO
                         ▼                       ▼
              ┌──────────────────┐    ┌──────────────────┐
              │ Mark note spent  │    │ Continue scan    │
              │ Update balance   │    │                  │
              │ Log detection    │    │                  │
              └──────────────────┘    └──────────────────┘
```

## Balance/History Reconciliation (FIX #162)

### Formula

```
BALANCE = Sum of all UNSPENT notes

HISTORY VERIFICATION:
  Total RECEIVED (from all notes) - Total SENT - Total FEES = Current UNSPENT
```

### Auto-Repair Process

```
1. Compare note-based balance vs history-based balance
2. If mismatch detected:
   - Delete transaction_history table contents
   - Rebuild from notes:
     - RECEIVED: Create entry for each note
     - SENT: Group spent notes by spent_in_tx
     - Calculate: sent = inputs - change - fee
3. Verify rebuilt history matches note balance
```

## Database Schema

### sync_state Table

```sql
CREATE TABLE sync_state (
    id INTEGER PRIMARY KEY,
    last_scanned_height INTEGER NOT NULL DEFAULT 0,
    last_scanned_hash BLOB,
    verified_checkpoint_height INTEGER NOT NULL DEFAULT 0  -- FIX #165
);
```

### notes Table (relevant columns)

```sql
CREATE TABLE notes (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    account_id INTEGER NOT NULL,
    cmu BLOB NOT NULL,           -- Note commitment
    nullifier BLOB NOT NULL,     -- Unique identifier for spending
    value INTEGER NOT NULL,      -- Amount in zatoshis
    is_spent INTEGER DEFAULT 0,  -- 0=unspent, 1=spent
    spent_in_tx BLOB,            -- TXID that spent this note
    spent_height INTEGER,        -- Block height where spent
    witness BLOB,                -- Merkle witness for spending
    anchor BLOB,                 -- Tree root when witness built
    ...
);
```

## Key Files

| File | Purpose |
|------|---------|
| `WalletHealthCheck.swift` | Health checks 1-12 including checkpoint sync |
| `WalletManager.swift` | Startup flow, sync, checkpoint updates |
| `NetworkManager.swift` | P2P connections, incoming TX confirmation |
| `FilterScanner.swift` | Block scanning, note discovery |
| `WalletDatabase.swift` | Checkpoint storage, note queries |
| `ContentView.swift` | FAST/FULL START decision logic |

## Configuration

| Parameter | Value | Location |
|-----------|-------|----------|
| Min peers for consensus | 3 | NetworkManager |
| Min peers for sync | 3 | HeaderSyncManager |
| Health check timeout | 30s | WalletHealthCheck |
| Checkpoint scan batch | 50 blocks | WalletHealthCheck |
| FAST START threshold | 50 blocks behind | ContentView |

## Troubleshooting

### Wrong Balance

1. **Settings → Repair Database** - Rebuilds history from notes
2. If still wrong, check health check results in log
3. Look for "FIX #164" or "FIX #165" log entries

### Missing Incoming Transaction

1. Check if checkpoint was before the transaction
2. Run health checks manually (relaunch app)
3. Check P2P connectivity
4. Verify spending key is correct

### Note Shown as Unspent When Spent

1. FIX #164 should detect this automatically
2. Check log for "🚨 FIX #164: Note X was spent"
3. If not detected, manually run "Repair Database"

## Changelog

- **FIX #164**: Nullifier verification health check at startup
- **FIX #165**: Checkpoint-based sync for all missed transactions
- **FIX #165 v2**: Checkpoint only updated on TX CONFIRMATION (mined), not mempool
  - Removed checkpoint update from send functions
  - Added checkpoint update to `confirmOutgoingTx()` and `confirmIncomingTx()`
  - Fixes edge case where other wallet instances can send while TX is pending
- **FIX #162**: Balance reconciliation with auto-repair
