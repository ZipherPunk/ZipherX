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
- FIX #154: FAST START progress bar stuck at 0%
- FIX #155: Show failed health check name in UI
- FIX #156: Add 'Rebuild witnesses' task with progress bar

## Security Score: 100/100

All 28 vulnerabilities fixed. See [docs/SECURITY.md](./docs/SECURITY.md).
