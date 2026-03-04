# ZipherX Security

## Security Score: 100/100

All 28 vulnerabilities from the security audit have been addressed.

## Security Checklist

- [x] All private keys encrypted at rest (Secure Enclave + AES-GCM-256)
- [x] Secure Enclave used for key operations (SecureKeyStorage.swift)
- [x] Multi-peer consensus implemented (consensusThreshold = 5)
- [x] Sapling proofs verified locally (LocalTxProver)
- [x] BIP39 mnemonic backup & restore (24-word seed phrases via FFI)
- [x] No sensitive data in logs (DEBUG_LOGGING flag)
- [x] Network traffic encrypted (P2P + Tor)
- [x] Memory protection for spending keys (SecureData wrapper + Rust zeroing)
- [x] App lock with biometric auth (Face ID / Touch ID)
- [x] Inactivity timeout auto-lock (configurable)
- [x] SQLCipher full database encryption
- [x] Field-level encryption for sensitive data
- [x] Nullifier hashing for privacy
- [x] Transaction type obfuscation
- [x] Secure memo deletion

## Critical Security Requirements

**NEVER:**
- Store unencrypted private keys
- Trust a single network peer
- Skip proof verification
- Disable SSL verification
- Use hardcoded credentials
- Log sensitive data in production

**ALWAYS:**
- Use Secure Enclave for spending key operations
- Require multi-peer consensus for queries
- Verify Sapling proofs locally
- Backup before encryption operations

## Encryption Layers

### 1. Key Storage (SecureKeyStorage.swift)

| Platform | Method | Key Derivation |
|----------|--------|----------------|
| iOS Device | Secure Enclave | Hardware EC key |
| iOS Simulator | AES-GCM-256 | HKDF(UDID + salt) |
| macOS | AES-GCM-256 | HKDF(Hardware UUID + salt) |

### 2. Database (SQLCipher)
- Full AES-256 database encryption
- Key derived from device ID + salt via HKDF-SHA256
- Automatic migration for existing databases

### 3. Field-Level (DatabaseEncryption.swift)
- AES-GCM-256 for sensitive fields
- Encrypted: diversifier, rcm, memo, witness
- 12-byte nonce + 16-byte auth tag per field

### 4. FFI Key Handling (VUL-002 Fix)
- Spending keys decrypted ONLY in Rust
- `zipherx_build_transaction_encrypted()` accepts encrypted key
- `secure_zero()` uses volatile writes + compiler fence
- Decrypted key zeroed immediately after use

## Sybil Attack Protection

- Consensus threshold: 5 peers must agree
- Fake height detection: reject heights >1000 blocks ahead of cached
- Auto-ban: 7 days for peers reporting fake data
- HeaderStore validation for all chain heights

## Vulnerability Fixes Summary

### P0 Critical (All Fixed)
1. VUL-001: Consensus threshold increased to 5
2. VUL-002: Encryption mandatory, no plaintext fallback
3. VUL-003: Equihash PoW verification enabled
4. VUL-004: Multi-input transactions supported

### P1 High (All Fixed)
5. VUL-005: Passcode required when biometric disabled
6. VUL-006: P2P-first chain height (InsightAPI is fallback)
7. VUL-007: SQLCipher required, no plaintext DB
8. VUL-008: Explicit memory zeroing for keys

### P2 Medium (All Fixed)
- VUL-010: 7-day peer ban duration
- VUL-011: Per-peer rate limiting
- VUL-018: Shared constants file
- VUL-020: Memo validation (512 byte limit)

### P3 Low (All Fixed)
- VUL-024: Dust output detection (10,000 zatoshis)
- VUL-009: Nullifiers hashed before storage
- VUL-014: Annual key rotation policy
- VUL-015: Transaction type obfuscation
- VUL-016: Secure memo deletion

## macOS Entitlements (Hardened Runtime)

macOS builds run with Hardened Runtime enabled and full library validation. The entitlement set has been minimized through testing and audit — only genuinely required entitlements remain.

### Golden Entitlement Set (v4.2.2)

| Entitlement | Value | Justification |
|---|---|---|
| `com.apple.security.app-sandbox` | `false` | Required: Full Node subprocess execution (`zclassicd`), P2P inbound connections, filesystem access for blockchain data outside app container |
| `com.apple.security.files.user-selected.read-write` | `true` | Required: User-initiated file operations (wallet export, backup) |
| `com.apple.security.network.client` | `true` | Required: Outbound P2P connections to Zclassic network peers |
| `com.apple.security.network.server` | `true` | Required: Inbound P2P connections from Zclassic network peers |
| `keychain-access-groups` | Team ID scoped | Required: Wallet spending key storage in macOS Keychain |

### Removed Entitlements (verified unnecessary)

| Entitlement | Removed In | Evidence |
|---|---|---|
| `com.apple.security.cs.allow-unsigned-executable-memory` | v4.2.2 | Groth16 zk-SNARK proof generation (heaviest crypto path) verified working without it. Rust FFI static library (`libzipherx_ffi.a`) contains no JIT or `mmap`/`mprotect` calls. |
| `com.apple.security.cs.disable-library-validation` | v4.2.2 | ZipherXFFI is a statically linked library (`.a`), not a dynamic framework — library validation does not apply. All embedded dylibs (Debug-only) are signed with the same Team ID. |
| `com.apple.security.device.audio-input` | v4.2.2 | Voice calls not included in beta release. |

### iOS Entitlements

| Entitlement | Value | Notes |
|---|---|---|
| `keychain-access-groups` | Team ID scoped | Spending key storage |
| `UIBackgroundModes` | `fetch` | Background sync only. `audio` mode removed in v4.2.2. |

### Sandbox Roadmap

App Sandbox (`com.apple.security.app-sandbox: true`) is a long-term goal. Current blockers:
- Full Node mode requires `Process()` execution of bundled `zclassicd` binary
- Blockchain data stored at `~/Library/Application Support/ZipherX/` (outside app container)
- Migration to container paths + security-scoped bookmarks required

Compensating controls while non-sandboxed:
- Hardened Runtime enabled with full library validation
- DYLD injection guard (fail-closed in Release, see MAC-HARDEN-1 below)
- No dynamic plugin loading
- All frameworks statically linked and signed
- Code signed and notarized by Apple
- Inbound P2P connections rate-limited with peer banning

### CI Entitlement Gate

The DMG packaging pipeline should assert that removed entitlements do not reappear:

```bash
#!/bin/bash
# Verify entitlements after notarization
ENTITLEMENTS=$(codesign --display --entitlements :- ZipherXMac.app 2>&1)

# These must NOT be present
for BANNED in "allow-unsigned-executable-memory" "disable-library-validation" "device.audio-input"; do
    if echo "$ENTITLEMENTS" | grep -q "$BANNED"; then
        echo "FAIL: Banned entitlement found: $BANNED"
        exit 1
    fi
done

echo "PASS: Entitlements are clean"
```

## Audit Reports

### MAC-HARDEN-1: DYLD Injection Guard — IMPLEMENTED (v4.2.2)

Prevents environment-based dynamic library injection (`DYLD_INSERT_LIBRARIES`, `DYLD_LIBRARY_PATH`, `DYLD_FRAMEWORK_PATH`) — a common macOS malware and red-team technique.

- **Release builds**: fail closed with user-facing alert and `exit(173)` on detection of high-signal `DYLD_*` variables. Lower-signal fallback variables are silently scrubbed.
- **Debug builds**: all variables silently scrubbed to preserve Xcode/Instruments workflows.
- **Placement**: file-level static initializer in `ZipherXApp.swift` — runs before `@main`, before SwiftUI init, before Rust FFI loads.
- **Complements**: Hardened Runtime + library validation ON + no `allow-unsigned-executable-memory`.

### P0-MAC-1: Hardened Runtime Exceptions — RESOLVED (v4.2.2)

Both `allow-unsigned-executable-memory` and `disable-library-validation` removed and verified by exercising the heaviest crypto path (Groth16 proof generation, 3.7s multi-spend transaction) and multi-peer consensus sync with no crashes.

Residual risk: macOS remains non-sandboxed with inbound networking capability. Mitigations: CI entitlement gates, listener hardening (rate limiting + peer bans), sandbox roadmap.

### P1-IOS-1: Background Mode Audit — RESOLVED (v4.2.2)

`audio` background mode and microphone usage description removed from iOS (`Info.plist`, `project.yml`). Only `fetch` background mode remains for periodic sync.

### P2-IOS-2: Mnemonic Backup UX — RESOLVED (v4.2.2)

App no longer locks when user backgrounds during mnemonic backup (e.g., switching to Notes/Photos to save seed phrase). Privacy overlay still activates in app switcher. Lock skipped only when `isMnemonicBackupPending` is true (wallet just created, no balance to protect).

### UX-SAFETY-1: Cellular Data Warning — IMPLEMENTED

iOS displays a warning banner when the ~2 GB boost file download is running on cellular data. The warning recommends switching to WiFi for faster speeds and to avoid data charges. The download is not blocked — it works on cellular with full resume support (HTTP Range headers, 30s stall timeout, exponential backoff up to 8 retries). If the network switches mid-download, the Rust download engine detects the stall, retries, and resumes from the last byte written.

### UX-SAFETY-2: Send-Path Integrity Firewall — IMPLEMENTED

Four-layer defense against transaction tampering:

| Layer | Attack | Defense |
|-------|--------|---------|
| VUL-UI-002 | Clipboard-swap (malware replaces address after paste) | Address snapshot at confirmation, re-verified before signing |
| VUL-UI-003 | Vanity address (attacker generates similar-looking address) | Segmented address display highlighting the unique middle section + SHA-256 fingerprint |
| VUL-UI-004 | Amount/fee manipulation | TX preview fingerprint (address + amount + fee) snapshotted and re-verified |
| Input validation | Invisible Unicode injection | Non-ASCII characters rejected in address field |

### Reports

- Full audit: `docs/SECURITY_AUDIT_FULL_2025-12-04.html`
- Previous audit: `docs/SECURITY_AUDIT_REPORT.html`

## Memory Protection

### SecureData Wrapper
```swift
// Keys wrapped in SecureData for automatic zeroing
class SecureData {
    deinit {
        // memset_s zeroes memory on deallocation
    }
}
```

### Rust-side Zeroing
```rust
fn secure_zero(data: &mut [u8]) {
    for byte in data.iter_mut() {
        unsafe { ptr::write_volatile(byte, 0); }
    }
    std::sync::atomic::compiler_fence(Ordering::SeqCst);
}
```
