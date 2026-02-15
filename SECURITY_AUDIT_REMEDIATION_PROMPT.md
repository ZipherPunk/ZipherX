# ZipherX Security Audit Remediation — Consolidated Report

## Current Status (2026-02-15 Update — Revision 3.1)

| Metric | Count |
|--------|-------|
| Original findings | 42 (10 CRITICAL, 12 HIGH, 13 MEDIUM) |
| Tasks FIXED | 3/25 |
| Tasks PARTIALLY FIXED | 12/25 |
| Tasks OPEN | 10/25 |
| Tasks REGRESSED | 0/25 |
| NEW findings since audit | 5 |
| **Updated Score** | **C- (HIGH RISK — Not Production Ready)** |

### Summary by Severity

| Severity | Fixed | Partial | Open | Total |
|----------|-------|---------|------|-------|
| CRITICAL | 0 | 2 | 5 | 7 |
| HIGH | 2 | 6 | 1 | 9 |
| MEDIUM | 1 | 4 | 4 | 9 |

> **v3.1 changes**: TASK 3 (VUL-F-004) upgraded HIGH→CRITICAL, TASK 25 (VUL-U-007) upgraded MEDIUM→CRITICAL. TASK 25 moved from Sprint 3 to Sprint 1 (blocks TASK 2). Grade downgraded C→C-.

### Key Improvements Since Audit
- SOCKS5 authentication response verification implemented (TASK 10) — ✅ FIXED
- Prepared transaction race condition fixed (TASK 21) — ✅ FIXED
- Null pointer checks added to FFI multi-input TX builder (TASK 7) — ✅ FIXED
- `DEBUG_DISABLE_ENCRYPTION = false` (TASK 1) — encryption IS active
- Log rotation system implemented (TASK 18, partial)
- IP address validation function implemented (TASK 24, partial)
- Rate limiter actor created (TASK 22, dead code — never called)
- `safe_lock!` macro applied to ~60% of mutex sites (TASK 4, partial)
- `safe_slice()` with alignment + overflow checks used in lib.rs (TASK 5, partial)
- Comprehensive Sybil detection + protocol version validation (Network layer)
- SQLCipher full-database encryption active with FULLMUTEX
- Secure Enclave key storage on iOS (with macOS fallback via Hardware UUID)

### Critical Remaining Risks
1. **VUL-U-001**: Private key clipboard export — no auth, no auto-clear, key persists in memory
2. **VUL-S-002**: Spending keys stored as plaintext BLOB in SQLite `accounts` table
3. **VUL-F-004**: `DEBUG_LOGGING = true` in Rust FFI — IVK, shared secrets, full TX hex actively leaked to unencrypted log file **(upgraded to CRITICAL)**
4. **VUL-U-007**: macOS key storage uses Hardware UUID (publicly readable) — deterministic spending key extraction by any local process **(upgraded to CRITICAL)**
5. **VUL-F-002**: Parallel decryption missing `checked_mul` — integer overflow possible
6. **VUL-F-001**: 21 remaining `.lock().unwrap()` calls — panic on poisoned mutex

---

## Context

On 2026-02-07, a comprehensive security audit was performed across all 4 layers of ZipherX:
- **Crypto/FFI**: lib.rs, download.rs, tor.rs, TransactionBuilder.swift, ZipherXFFI.swift, Bridging-Header.h
- **Network/P2P**: NetworkManager.swift, Peer.swift, PeerManager.swift, HeaderSyncManager.swift, FilterScanner.swift, HiddenServiceManager.swift, TorManager.swift
- **Storage/Wallet**: WalletDatabase.swift, DatabaseEncryption.swift, SQLCipherManager.swift, HeaderStore.swift, DeltaCMUManager.swift, WalletManager.swift, SecureKeyStorage.swift
- **UI/App**: ContentView.swift, AppDelegate.swift, SendView.swift, SettingsView.swift, FullNodeWalletView.swift, WalletSetupView.swift, BiometricAuthManager.swift

Full audit report: `/Users/chris/ZipherX/SECURITY_AUDIT_2026.html`

**Result: 42 findings (10 CRITICAL, 12 HIGH, 13 MEDIUM) + 7 positive practices**
**Original Score: C+ (MEDIUM-HIGH RISK - Not Production Ready)**

---

## PHASE 1: P0 - CRITICAL (Must Fix Before Any Production Release)

### TASK 1: Disable DEBUG_DISABLE_ENCRYPTION [VUL-S-001] [CRITICAL]
**STATUS**: ✅ PARTIALLY FIXED (core encryption active)

**What's fixed**: `DEBUG_DISABLE_ENCRYPTION = false` on line 30 of WalletDatabase.swift. `encryptBlob()` unconditionally calls `DatabaseEncryption.shared.encrypt()`. Field-level AES-GCM-256 encryption IS active for `diversifier`, `rcm`, `memo`, `witness`, and `tree_state` columns.

**What remains**:
1. Remove the vestigial `DEBUG_DISABLE_ENCRYPTION` flag and `isEncryptionEnabled` property entirely (they serve no purpose since `encryptBlob()` ignores them), OR add a compile-time guard:
   ```swift
   #if !DEBUG
   // Compile-time assertion: encryption MUST be enabled in release
   private static let DEBUG_DISABLE_ENCRYPTION = false
   #endif
   ```

**File**: `Sources/Core/Storage/WalletDatabase.swift` : lines 30, 62
**Testing**: Verify `getBalance()` returns correct values, `getAllUnspentNotes()` returns decryptable notes.

---

### TASK 2: Remove Spending Keys from Database [VUL-S-002] [CRITICAL]
**STATUS**: ❌ OPEN

**Evidence**: The `accounts` table schema STILL has `spending_key BLOB NOT NULL` (line 399). `insertAccount()` (line 975) binds raw spending key bytes with NO encryption. `getAccount()` (line 1019) reads back the raw spending key. No migration exists. Protection relies solely on SQLCipher full-database encryption.

**File**: `Sources/Core/Storage/WalletDatabase.swift` : lines 399, 975, 1019

**Required Changes**:
1. Remove `spending_key` column from accounts table (or zero it out)
2. Update `insertAccount()` to NOT store spending key bytes
3. Create migration to securely delete existing spending keys:
   ```swift
   sqlite3_exec(db, "UPDATE accounts SET spending_key = zeroblob(length(spending_key))", nil, nil, nil)
   ```
4. Update ALL code paths that READ `spending_key` to use `SecureKeyStorage.retrieveSpendingKey()` instead
5. Search for ALL references to `spending_key` column and update

**Testing**: Verify spending key retrieval from Secure Enclave works BEFORE removing DB keys. Test on both iOS and macOS. Test full TX signing flow.

**WARNING**: macOS unsigned builds use Hardware UUID-based encryption (TASK 25). Verify that path works before removing the DB fallback.

---

### TASK 3: Disable DEBUG_LOGGING in Rust FFI [VUL-F-004] [CRITICAL]
**STATUS**: ❌ OPEN

**Severity Upgrade**: Upgraded from HIGH to **CRITICAL** — IVK, shared secrets, and KDF material are actively written to an unencrypted log file (`zmac.log`) readable by any local process. This is equivalent to a live key exfiltration channel. Any malware or cohabitant process can extract the full viewing key for complete transaction surveillance.

**Evidence**: Line 13 of lib.rs: `const DEBUG_LOGGING: bool = true;` — still enabled. The `debug_log!` macro guards ~220+ log calls but they ALL fire. Additionally, ~324 unguarded `eprintln!()` calls print regardless of the flag.

**Sensitive data actively logged**:
- Full IVK scalar (lines 863, 921)
- Full EPK (line 920)
- pk_d bytes (line 871)
- Shared secret material (line 917)
- KDF key material (line 935)
- Diversifier plaintext (line 947)
- RCM values (line 6335)
- Full TX hex (line 6523)
- Nullifier values (line 2358)

**File**: `Libraries/zipherx-ffi/src/lib.rs` : line 13

**Required Changes**:
1. Set `const DEBUG_LOGGING: bool = false;` on line 13
2. Wrap ALL `eprintln!()` calls containing sensitive data (`hex::encode`, `EPK`, `IVK`, `diversifier`, `key`, `secret`, `cmu`, `nullifier`) in `if DEBUG_LOGGING {}`
3. For production builds, use compile-time gating:
   ```rust
   #[cfg(debug_assertions)]
   const DEBUG_LOGGING: bool = true;
   #[cfg(not(debug_assertions))]
   const DEBUG_LOGGING: bool = false;
   ```

**Testing**: Verify TX building and note decryption still work. Check zmac.log no longer contains hex-encoded key material.
**NOTE**: Requires recompiling the Rust FFI library.

---

### TASK 4: Fix .unwrap() Panics in Rust FFI [VUL-F-001, VUL-F-003] [CRITICAL]
**STATUS**: ⚠️ PARTIALLY FIXED

**What's fixed**: `safe_lock!` macro defined (lines 177-189) and used at ~30 call sites. Recovers from poisoned mutex.

**What remains**: 21 call sites still use raw `.lock().unwrap()`:
- PROVER: lines 1433, 1545
- VERIFYING_KEYS: lines 1439, 1551, 7470
- COMMITMENT_TREE: lines 2543, 2700, 2873, 3901
- WITNESSES: lines 2546, 2632, 2700, 2881, 3270, 4124
- TREE_POSITION: lines 2549, 2637, 3311, 3904
- DELTA_CMUS: lines 2555, 2623, 4112

**File**: `Libraries/zipherx-ffi/src/lib.rs`

**Required Changes**:
1. Replace ALL 21 `.lock().unwrap()` calls with `safe_lock!` macro
2. `safe_lock!` returns `Option<MutexGuard>` — each call site needs `match` or `?` handling

**Testing**: Verify tree operations, witness creation, and TX building all work.

---

### TASK 5: Fix Buffer Overflow in Parallel Decryption [VUL-F-002] [CRITICAL]
**STATUS**: ⚠️ PARTIALLY FIXED

**What's fixed**: Input validation via `safe_slice()` at lines 1070-1108 for sk, outputs_data, and results buffer. Pre-parsing uses safe slice indexing. Integer overflow protection using `saturating_sub` pattern confirmed in 6 tree-loading functions.

**What remains**:
1. Lines 1095 and 1102 use `output_count * 644` and `output_count * 564` with NO `checked_mul()` — zero `checked_mul` calls exist in the entire file
2. Lines 1150-1174 use raw pointer arithmetic (`out_ptr.add(result_offset)`, `ptr::copy_nonoverlapping`) bypassing Rust's borrow checker

**File**: `Libraries/zipherx-ffi/src/lib.rs` : lines 1058-1180

**Required Changes**:
1. Add `checked_mul` for all multiplication in parallel decryption:
   ```rust
   let total_output_size = output_count.checked_mul(644).unwrap_or(0);
   if total_output_size == 0 && output_count > 0 { return 0; }
   let total_result_size = output_count.checked_mul(564).unwrap_or(0);
   if total_result_size == 0 && output_count > 0 { return 0; }
   ```
2. Replace raw pointer arithmetic in parallel path with safe slice indexing

**Testing**: Verify parallel decryption works on blocks with known shielded outputs.

---

### TASK 6: Fix Private Key Clipboard Export [VUL-U-001] [CRITICAL]
**STATUS**: ❌ OPEN

**Evidence (SettingsView.swift)**:
- Line 119: `@State private var exportedKey = ""` — never cleared on dismissal
- Line 1897: `exportPrivateKey()` called with ZERO authentication
- Line 3194-3196: Directly calls `walletManager.exportSpendingKey()` without auth gate
- Line 231: `copyToClipboard(exportedKey)` — raw clipboard write, no auto-clear
- Line 234: Full private key displayed in alert text (accessible to screen readers, memory)

**Evidence (FullNodeWalletView.swift)**:
- Line 934: `@State private var exportedPrivateKey: String = ""` — never cleared
- Line 1079: Export button with no authentication
- Line 1104: Private key displayed in plaintext in sheet
- Line 1112: `copyToClipboard(exportedPrivateKey)` — no auto-clear

**File**: `Sources/Features/Settings/SettingsView.swift` : lines 119, 231, 234, 1897, 3194
**File**: `Sources/Features/FullNodeWallet/FullNodeWalletView.swift` : lines 934, 1079, 1104, 1112

**Required Changes**:
1. **Add biometric authentication** before key export (BiometricAuthManager already has `authenticateForKeyExport()` method):
   ```swift
   private func exportPrivateKey() {
       BiometricAuthManager.shared.authenticateForKeyExport { success, _ in
           guard success else { return }
           // ... existing export logic
       }
   }
   ```
2. **Implement clipboard auto-clear** (10 seconds for private keys):
   ```swift
   #if os(macOS)
   NSPasteboard.general.clearContents()
   NSPasteboard.general.setString(exportedKey, forType: .string)
   DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
       NSPasteboard.general.clearContents()
   }
   #endif
   ```
3. **Clear `exportedKey` on alert dismissal**: `.onDisappear { exportedKey = "" }`
4. **Show truncated key** in alert text instead of full key
5. **Apply same fixes to FullNodeWalletView.swift**

**Testing**: Verify key can still be exported. Verify clipboard auto-clears after 10s.

---

### TASK 7: Add Null Pointer Checks in Multi-Input TX Builder [VUL-F-006] [HIGH]
**STATUS**: ✅ FIXED

**Evidence**: `zipherx_build_transaction_multi()` (lines 2016-2130) has comprehensive null/validity checks via `safe_slice()` for all inputs. Per-spend validation checks witness, rcm, and diversifier pointers individually. `zipherx_build_transaction_multi_encrypted()` (line 6547) follows the same pattern. `safe_slice()` includes alignment validation and integer overflow protection.

**No further changes needed.**

---

## PHASE 2: P1 - HIGH PRIORITY (Before Launch)

### TASK 8: Implement Side-Channel Protections [VUL-F-005] [HIGH]
**STATUS**: ⚠️ PARTIALLY FIXED

**What's fixed**: `subtle = "2.5"` in Cargo.toml. `CtOption` used in Groth16 verification. Custom `secure_zero()` function (lines 5957-5966) using `write_volatile` + `compiler_fence` — used for spending key zeroing after TX build (lines 6495-6503, 6978-6980).

**What remains**:
1. Line 965: Diversifier comparison uses variable-time `==` instead of `ConstantTimeEq`
2. `zeroize` crate NOT in Cargo.toml
3. KDF key (line 928), `kdf_input` (line 924), `cipher_key` (line 938) NOT zeroed after use

**File**: `Libraries/zipherx-ffi/src/lib.rs` : lines 924, 928, 938, 965

**Required Changes**:
1. Replace line 965 with constant-time comparison:
   ```rust
   use subtle::ConstantTimeEq;
   if plaintext[1..12].ct_eq(&our_div).into() {
   ```
2. Add `zeroize = "1"` to Cargo.toml and zero symmetric keys after use
3. Zero `kdf_input`, `cipher_key`, and KDF output after use

**Testing**: Verify decryption still works. Negligible performance impact.

---

### TASK 9: Fix P2P Message Validation [VUL-N-004] [HIGH]
**STATUS**: ⚠️ PARTIALLY FIXED

**What's fixed**: `parseIPAddress()` has proper buffer validation. Checksum validation via doubleSHA256 (FIX #1139). Protocol version validation rejects wrong-chain peers.

**What remains**:
1. **NO maximum payload size** in `receiveMessage()` and `receiveMessageTolerant()` — UInt32 length field allows up to 4GB allocation → OOM crash from malicious peer
2. `parseRejectTxid()` reads single-byte count instead of proper CompactSize varint
3. `parseAddrPayload()` has same single-byte count parsing

**File**: `Sources/Core/Network/Peer.swift`

**Required Changes**:
1. Add max payload size validation:
   ```swift
   guard payloadLength <= 4_000_000 else { // 4MB max per Bitcoin protocol
       throw NetworkError.invalidMessage
   }
   ```
2. Implement proper CompactSize varint decoding in `parseRejectTxid()` and `parseAddrPayload()`

**Testing**: Verify header sync, block fetch, and broadcast all work.

---

### TASK 10: Fix SOCKS5 Authentication Verification [VUL-N-007] [HIGH]
**STATUS**: ✅ FIXED

**Evidence**: `performSocks5UsernameAuth()` (lines 1762-1805) validates: response length == 2, auth version == 0x01, status == 0x00. Initial handshake validates version (0x05) and method selection. Dynamic random credentials per circuit with UUID-based passwords for Tor circuit isolation.

**No further changes needed.**

---

### TASK 11: Fix Broadcast Handler Race Condition [VUL-N-005] [HIGH]
**STATUS**: ⚠️ PARTIALLY FIXED

**What's fixed**: Primary path requires explicit txid matching. `PeerMessageDispatcher` is an `actor` preventing concurrent mutation. Timeout handling uses GCD-based `withReliableTimeout`.

**What remains**: Lines 198-204 still deliver reject to "any broadcast handler" when txid doesn't match:
```swift
if let (key, handler) = broadcastHandlers.first {
    broadcastHandlers.removeValue(forKey: key)
    handler.resume(returning: (command, payload))
    return true
}
```
If two broadcasts are in flight, a reject for TX-A could be delivered to TX-B's handler.

**File**: `Sources/Core/Network/Peer.swift` : lines 198-204

**Required Changes**:
1. Remove the "any handler" fallback. If txid doesn't match, log and drop:
   ```swift
   // Unmatched reject - log and drop
   print("⚠️ Reject message with unmatched txid - dropping")
   return false
   ```

**Testing**: Verify TX broadcast and confirmation detection still work.

---

### TASK 12: Implement Clipboard Auto-Clear Across All Views [VUL-U-003] [HIGH]
**STATUS**: ❌ OPEN

**Evidence**: 12+ files write to clipboard with zero auto-clear. Each view has its own identical `copyToClipboard()` function using raw `NSPasteboard.general.setString()`. No shared utility exists.

**Affected files**: SettingsView, SendView, ReceiveView, ChatView, HistoryView, ExplorerView, FullNodeWalletView, RPCSendView, RPCTransactionHistoryView, NodeManagementView, and more.

**Required Changes**:
1. Create a shared utility:
   ```swift
   static func copyWithAutoExpiry(_ text: String, seconds: TimeInterval = 60) {
       #if os(iOS)
       UIPasteboard.general.setItems(
           [[UIPasteboard.typeAutomatic: text]],
           options: [.expirationDate: Date().addingTimeInterval(seconds)]
       )
       #else
       NSPasteboard.general.clearContents()
       NSPasteboard.general.setString(text, forType: .string)
       DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
           NSPasteboard.general.clearContents()
       }
       #endif
   }
   ```
2. Replace ALL direct clipboard writes (use 10s for keys, 60s for addresses/txids)

**Testing**: Verify clipboard operations work. Verify auto-clear fires.

---

### TASK 13: Remove Localhost from P2P Seed List [VUL-N-003, VUL-N-014] [HIGH]
**STATUS**: ⚠️ PARTIALLY FIXED

**What's fixed**: Runtime filters prevent actual connections in ZipherX mode:
- Line 2427: `validPeers.filter { $0.host != "127.0.0.1" }`
- Line 4675: `if !isFullNodeMode && seedNode == "127.0.0.1" { continue }`

**What remains**: `127.0.0.1` is still in `HARDCODED_SEEDS` (line 749) and is exempt from cooldown (line 760) — always retried and logged before being filtered.

**File**: `Sources/Core/Network/NetworkManager.swift` : line 749

**Required Changes**:
1. Remove `"127.0.0.1"` from `HARDCODED_SEEDS`
2. Add localhost dynamically only when Full Node mode is configured
3. Remove cooldown exemption for hardcoded seeds (or limit it)

**Testing**: Verify peer discovery still works.

---

## PHASE 3: P2 - MEDIUM PRIORITY (Next Release)

### TASK 14: Implement Per-User Random PIN Salt [VUL-U-004] [MEDIUM]
**STATUS**: ❌ OPEN

**Evidence**: Fixed salt `"ZipherX_PIN_Salt_v1"` hardcoded at line 15 of SettingsView.swift. Only 10,000 rounds of SHA256 (not PBKDF2/Argon2). PIN verification at line 72 and 99 uses non-constant-time `==` comparison. With fixed salt and max 1M PIN combinations, offline brute-force takes under a second.

**File**: `Sources/Features/Settings/SettingsView.swift` : lines 15, 26-39, 72, 99

**Required Changes**:
1. Generate random 32-byte salt on first PIN setup, stored in Keychain
2. Use PBKDF2 or Argon2id instead of iterated SHA256
3. Use constant-time comparison for PIN verification
4. Migration: verify existing PINs with old salt, re-hash with new salt

**Testing**: Set PIN, verify, restart, verify again. Ensure migration from old salt works.

---

### TASK 15: Fix Database Race Conditions [VUL-S-003] [CRITICAL but P2]
**STATUS**: ⚠️ PARTIALLY FIXED

**What's fixed**: `SQLITE_OPEN_FULLMUTEX` applied (line 211) — provides per-call thread safety. Some multi-statement operations ARE transactional: `insertNotesBatch()` uses `BEGIN IMMEDIATE TRANSACTION` (line 1199), `recordSentTransactionAtomic()` uses `BEGIN IMMEDIATE TRANSACTION` (line 1777).

**What remains**:
1. Serial queue declared at line 156 but **NEVER used** (zero `queue.sync` or `queue.async` calls)
2. Many multi-step operations NOT transactional: `markNoteSpentByHashedNullifier()` does SELECT + UPDATE without transaction (TOCTOU vulnerability)
3. Migration 6 uses non-exclusive `BEGIN TRANSACTION` (line 703) with discarded result

**File**: `Sources/Core/Storage/WalletDatabase.swift` : lines 156, 211, 703

**Required Changes**:
1. Either use the declared `queue` for ALL public methods, or remove it (misleading dead code)
2. Wrap ALL multi-statement read-then-write operations in `BEGIN EXCLUSIVE TRANSACTION`
3. Fix migration 6 to check `BEGIN TRANSACTION` result

**Testing**: Run concurrent read/write operations. Verify no deadlocks.

---

### TASK 16: Encrypt Remaining Sensitive Fields [VUL-S-004] [CRITICAL but P2]
**STATUS**: ⚠️ PARTIALLY FIXED

**What's encrypted**: `diversifier`, `rcm`, `memo`, `witness`, `tree_state` via `encryptBlob()`
**What's NOT encrypted**: `value` (INT64), `received_height`, `received_in_tx`, `spent_in_tx`, `spent_height`, `is_spent`

**Note**: Encrypting `value` would break SQL aggregation in `getBalance()` — requires application-level computation.

**File**: `Sources/Core/Storage/WalletDatabase.swift`

**Required Changes**:
1. Encrypt `value`, `received_height`, `spent_height`, `received_in_tx`, `spent_in_tx`
2. Refactor `getBalance()` and `getTotalUnspentBalance()` to application-level sum
3. Update ALL queries reading these fields to decrypt after reading

**Testing**: Verify balance calculations. Verify TX history displays correctly.

---

### TASK 17: Add Screenshot Protection [VUL-U-006] [MEDIUM]
**STATUS**: ⚠️ PARTIALLY FIXED

**What's fixed**: Lock screen shown on `.background` phase.

**What remains**:
1. `.inactive` phase does NOTHING — full wallet UI visible in iOS app switcher
2. Screenshot notification only calls `recordUserActivity()` — no warning
3. No `NSWindow.sharingType = .none` for macOS screen recording protection

**File**: `Sources/App/ContentView.swift`

**Required Changes**:
1. Add blur overlay on `.inactive` for app switcher
2. Add screenshot warning notification
3. On macOS, set `window.sharingType = .none`

---

### TASK 18: Secure Log Files [VUL-N-009] [MEDIUM]
**STATUS**: ⚠️ PARTIALLY FIXED

**What's fixed**: `LogRedaction` struct exists in DebugLogger.swift (lines 426-519) with 7 redaction functions. Log rotation implemented (FIX #763, keeps 10 backups).

**What remains**:
1. **All 7 redaction functions are DEAD CODE** — zero usage outside DebugLogger.swift
2. No `LogLevel` enum or `secureLog()` function
3. Sensitive data actively logged in plaintext: .onion addresses, TX amounts, raw TX hex
4. No time-based retention (only count-based)
5. No log file encryption at rest

**Files**: `Sources/Core/Services/DebugLogger.swift`, 8+ files with sensitive `print()` statements

**Required Changes**:
1. Apply existing `LogRedaction` functions to ALL ~40 sensitive print statements
2. Implement log level filtering for release builds
3. Add 7-day time-based log rotation

---

### TASK 19: Fix TX Type Obfuscation [VUL-S-005] [HIGH but P2]
**STATUS**: ⚠️ PARTIALLY FIXED

**What's done**: Greek letter substitution (`sent→α`, `received→β`, `change→γ`) applied consistently.

**What remains**: This is a fixed deterministic substitution cipher with only 3 symbols — NOT encryption. The CHECK constraint reveals the substitution table in the schema.

**File**: `Sources/Core/Storage/WalletDatabase.swift` : lines 87-106

**Required Changes**:
1. Replace substitution with AES-GCM encryption using `encryptBlob()`
2. Change column type from TEXT to BLOB
3. Remove Greek letter mapping and CHECK constraint

---

### TASK 20: Fix Unbounded DELTA_CMUS Growth [VUL-F-008] [MEDIUM]
**STATUS**: ❌ OPEN

**Evidence**: `DELTA_CMUS` is `Mutex<Vec<Node>>` (line 2538) with NO capacity limit. Push operations at lines 2623 and 2839 have no bounds check. `clear()` calls don't `shrink_to_fit()`.

**File**: `Libraries/zipherx-ffi/src/lib.rs` : line 2538

**Required Changes**:
1. Add `MAX_DELTA_CMUS = 100_000` capacity limit
2. Call `shrink_to_fit()` after clearing
3. Apply to both push sites (lines 2623, 2839)

---

### TASK 21: Fix Prepared Transaction Race Condition [VUL-U-005] [MEDIUM]
**STATUS**: ✅ FIXED

**Evidence**: `invalidatePreparedTransaction()` properly handles all race vectors: cancels debounce task, cancels preparation task, resets state. Called in all required places: address change, amount change, send start, invalid input. `triggerPreparationIfNeeded()` validates prepared TX matches current input before reuse.

**No further changes needed.**

---

### TASK 22: Implement P2P Rate Limiting [VUL-N-008] [HIGH but P2]
**STATUS**: ⚠️ PARTIALLY FIXED (Dead Code)

**What exists**: `PeerRateLimiter` actor (lines 495-551) with token bucket algorithm (100 tokens, 10/sec refill). Each `Peer` instance creates one (line 571).

**What remains**: `tryConsume()` and `waitForToken()` are **NEVER called** from any code path — zero usage across entire codebase. The rate limiter is instantiated but completely inert.

**File**: `Sources/Core/Network/Peer.swift` : lines 495-551

**Required Changes**:
1. Call `rateLimiter.tryConsume()` before each outbound P2P request
2. Add max pending request queue (100 max) with rejection when full
3. Integrate into `sendMessage()`, `requestHeaders()`, `requestBlocks()`

---

### TASK 23: Fix Migration Transaction Safety [VUL-S-006] [MEDIUM]
**STATUS**: ⚠️ PARTIALLY FIXED

**What's fixed**: Migration 6 (lines 700-781) IS wrapped in `BEGIN TRANSACTION` / `COMMIT` / `ROLLBACK`. `insertNotesBatch()` and `recordSentTransactionAtomic()` use `BEGIN IMMEDIATE TRANSACTION`.

**What remains**:
1. Migration 6 uses non-exclusive `BEGIN TRANSACTION` (not `BEGIN EXCLUSIVE`)
2. Migration 6 result discarded with `_ =` (line 703) — continues if BEGIN fails
3. Migrations 1-5 and 7-14 NOT wrapped in any transaction
4. No outer transaction wrapping all migrations together

**File**: `Sources/Core/Storage/WalletDatabase.swift` : lines 568-962, 703

**Required Changes**:
1. Wrap ALL migrations in `BEGIN EXCLUSIVE TRANSACTION` with ROLLBACK on failure
2. Check BEGIN result — don't discard with `_ =`

---

### TASK 24: Validate IP Addresses for Reserved Ranges [VUL-N-012] [MEDIUM]
**STATUS**: ⚠️ PARTIALLY FIXED

**What's fixed**: `isReservedIPAddress()` function exists (lines 1305-1340) covering ALL major reserved ranges (0/8, 10/8, 127/8, 169.254/16, 172.16-31/12, 192.168/16, 224-255).

**What remains**: Only called at ONE site (line 7822, parked peer reconnection). NOT called in:
- `addAddress()` (line 1224) — main entry point for discovered peers
- `parseIPAddress()` in Peer.swift — only filters 255.255.x.x and 0.x.x.x
- Peer selection paths

Malicious peers can advertise RFC 1918 addresses via `addr` messages and they will be accepted.

**File**: `Sources/Core/Network/NetworkManager.swift` : lines 1224, 1305, 7822
**File**: `Sources/Core/Network/Peer.swift` : `parseIPAddress()`

**Required Changes**:
1. Call `isReservedIPAddress()` in `addAddress()` (main entry for all discovered addresses)
2. Call `isReservedIPAddress()` in `parseIPAddress()` in Peer.swift
3. Add RFC 6598 (100.64/10) to the filter

---

### TASK 25: Fix macOS Key Access Security [VUL-U-007] [CRITICAL]
**STATUS**: ❌ OPEN

**Severity Upgrade**: Upgraded from MEDIUM to **CRITICAL** — Hardware UUID is publicly readable via `ioreg -rd1 -c IOPlatformExpertDevice` by any local process. Combined with the on-disk `.enc` file and salt, this is a deterministic spending key extraction path requiring zero privileges beyond same-user access. Any macOS malware running as the user can silently steal all funds.

**Evidence**: ALL macOS builds bypass Secure Enclave (line 73: `if isMacOS { ... storeKeySimpleMacOS ... }`). File-based storage writes AES-GCM encrypted data with encryption key derived from Hardware UUID (lines 398-437) via IOKit `kIOPlatformUUIDKey` — **publicly readable by any process** (`ioreg`, `system_profiler`). Salt stored as unprotected plaintext file. Key retrieval requires ZERO authentication.

**Complete attack**: Any process running as the same user can read `.enc` file + salt + Hardware UUID → derive key via HKDF-SHA256 → decrypt spending key.

**File**: `Sources/Core/Storage/SecureKeyStorage.swift` : lines 73-80, 335-476, 398-437

**Required Changes**:
1. Migrate to macOS Keychain Services with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
2. Add `kSecUseUserPresence` context for biometric/password gating
3. Create migration: read existing .enc key, store in Keychain, securely delete .enc file
4. Fallback: if Keychain unavailable, use password-derived key (PBKDF2/Argon2) instead of Hardware UUID

**WARNING**: MUST be completed BEFORE TASK 2 (removing spending key from DB) — the DB copy is the only remaining backup if macOS key storage fails.

**Testing**: Verify key retrieval prompts for auth on macOS. Verify iOS Secure Enclave still works.

---

## NEW FINDINGS (Post-Audit)

### NEW-001: LogRedaction Functions Are Dead Code [MEDIUM]
**Evidence**: `LogRedaction` struct in DebugLogger.swift (lines 426-519) defines 7 redaction functions. **Zero usage** outside of DebugLogger.swift. All sensitive `print()` statements use raw values.

**Impact**: False sense of security.
**Remediation**: Apply existing functions to all ~40 sensitive print statements.

---

### NEW-002: PeerRateLimiter Is Dead Code [MEDIUM]
**Evidence**: `PeerRateLimiter` actor in Peer.swift (lines 495-551) — `tryConsume()` and `waitForToken()` are **NEVER called**. Rate limiter instantiated but completely inert.

**Impact**: False sense of security.
**Remediation**: Integrate rate limiter into outbound P2P request methods.

---

### NEW-003: Private Key Export in FullNodeWalletView Has Same Vulnerabilities [HIGH]
**Evidence**: FullNodeWalletView.swift has identical issues to TASK 6:
- `exportedPrivateKey` @State (line 934) never cleared
- `copyToClipboard(exportedPrivateKey)` (line 1112) — no auto-clear
- No biometric authentication before export (line 1079)

**Impact**: Same as TASK 6 — spending key exposure.
**Remediation**: Apply same fixes as TASK 6.

---

### NEW-004: Non-Constant-Time PIN Comparison [LOW]
**Evidence**: SettingsView.swift lines 72, 99 use `hashPIN(pin) == storedHash` — standard Swift `==` is NOT constant-time.

**Impact**: Low (requires precise local timing measurements).
**Remediation**: Use `Data` comparison with constant-time equality.

---

### NEW-005: Unguarded from_raw_parts in download.rs and tor.rs [MEDIUM]
**Evidence**: `download.rs` lines 108, 114, 340, 346 call `std::slice::from_raw_parts()` without null pointer validation or `safe_slice()` wrapper. These receive user-controlled lengths from the Swift caller.

**Files**: `Libraries/zipherx-ffi/src/download.rs` : lines 108, 114, 340, 346

**Remediation**: Replace with `safe_slice()` pattern used in lib.rs:
```rust
let url_slice = match safe_slice(url_ptr, url_len) {
    Some(s) => s,
    None => return 4,
};
```

---

## Execution Order (Updated)

### Sprint 1 (P0 — Do First)
- [ ] **TASK 3**: Disable DEBUG_LOGGING (Rust FFI — 1 line + wrap sensitive eprintlns)
- [ ] **TASK 6**: Fix private key clipboard + add biometric auth (UI — critical fund safety)
- [x] ~~TASK 7: Add null pointer checks (Rust FFI)~~ ✅ FIXED
- [x] ~~TASK 1: Disable DEBUG_DISABLE_ENCRYPTION~~ ✅ Core fix done
- [ ] **TASK 1** (remaining): Remove vestigial flag or add compile-time guard
- [ ] **TASK 5**: Fix buffer overflow — add checked_mul + safe slicing (Rust FFI)
- [ ] **TASK 4**: Replace remaining 21 .unwrap() with safe_lock! (Rust FFI)
- [ ] **TASK 25**: Fix macOS key access security *(upgraded from P2 — blocks TASK 2)*
- [ ] **TASK 2**: Remove spending keys from DB *(requires TASK 25 first)*

### Sprint 2 (P1 — Before Launch)
- [x] ~~TASK 10: Fix SOCKS5 auth verification~~ ✅ FIXED
- [x] ~~TASK 21: Fix prepared TX race condition~~ ✅ FIXED
- [ ] **TASK 12**: Clipboard auto-clear across all views (create shared utility, update 12+ files)
- [ ] **TASK 9**: Fix P2P message validation (add 4MB max payload, proper CompactSize)
- [ ] **TASK 13**: Remove localhost from seeds (move to dynamic for full-node mode)
- [ ] **TASK 11**: Fix broadcast handler race (remove "any handler" fallback)
- [ ] **TASK 8**: Side-channel protections (ConstantTimeEq, zeroize, KDF key zeroing)
- [ ] **NEW-003**: Fix FullNodeWalletView private key export (same as TASK 6)
- [ ] **NEW-005**: Fix unguarded from_raw_parts in download.rs

### Sprint 3 (P2 — Next Release)
- [ ] **TASK 14**: Per-user PIN salt (random salt, PBKDF2/Argon2, constant-time compare)
- [ ] **TASK 18**: Secure log files (apply redaction, add log levels, time-based rotation)
- [ ] **TASK 15**: Database race conditions (use queue or transactions for multi-step ops)
- [ ] **TASK 16**: Encrypt remaining sensitive fields (value, heights, txids)
- [ ] **TASK 23**: Migration transaction safety (wrap all in EXCLUSIVE transactions)
- [ ] **TASK 24**: IP address validation (apply isReservedIPAddress at all entry points)
- [ ] **TASK 17**: Screenshot protection (blur on .inactive, screenshot warning)
- [ ] **TASK 22**: P2P rate limiting (integrate existing dead-code rate limiter)
- [ ] **TASK 19**: TX type obfuscation (replace Greek letters with AES-GCM)
- [ ] **TASK 20**: Unbounded DELTA_CMUS (add MAX_DELTA_CMUS, shrink_to_fit)
- [ ] **NEW-001**: Apply LogRedaction functions (dead code → active)
- [ ] **NEW-002**: Integrate PeerRateLimiter (dead code → active)
- [ ] **NEW-004**: Non-constant-time PIN comparison

---

## Layer-by-Layer Security Summary

### Rust FFI Layer (lib.rs, download.rs, tor.rs)
| Control | Status | Notes |
|---------|--------|-------|
| Null pointer validation | ✅ PASS | `safe_slice()` with alignment + overflow checks |
| Buffer overflow protection | ⚠️ PARTIAL | Missing `checked_mul` in parallel decryption |
| Thread safety (Mutex) | ⚠️ PARTIAL | 21 of 51 lock sites still use raw `.unwrap()` |
| Integer overflow | ✅ PASS | `saturating_sub` pattern in 6 tree-loading functions |
| Memory zeroing | ✅ PASS | `secure_zero()` for spending keys after TX build |
| Debug logging | ❌ FAIL | **CRITICAL** — `DEBUG_LOGGING = true` — IVK, shared secrets, KDF material actively written to unencrypted log |
| DELTA_CMUS bounds | ❌ FAIL | No capacity limit, no `shrink_to_fit()` |
| Dependencies | ✅ PASS | No known CVEs in pinned versions |
| download.rs pointers | ❌ FAIL | 4 unguarded `from_raw_parts` calls |

### Network Layer (Peer.swift, NetworkManager.swift, TorManager.swift)
| Control | Status | Notes |
|---------|--------|-------|
| IP address filtering | ⚠️ PARTIAL | Function exists, only called at 1 of 3+ entry points |
| Message checksum | ✅ PASS | doubleSHA256 validation (FIX #1139) |
| Protocol version | ✅ PASS | Rejects wrong-chain peers, permanent bans |
| Sybil detection | ✅ PASS | Equihash verification + peer banning |
| Connection limits | ✅ PASS | MIN=8, MAX=30 peers enforced |
| Rate limiting | ❌ FAIL | Token bucket exists but NEVER called |
| Max payload size | ❌ FAIL | No cap — UInt32 allows 4GB allocation |
| SOCKS5 auth | ✅ PASS | Full RFC 1928 compliance |
| Tor circuit isolation | ✅ PASS | Dynamic UUID-based credentials per circuit |
| Broadcast handler | ⚠️ PARTIAL | "Any handler" fallback can misroute rejects |
| Localhost in seeds | ⚠️ PARTIAL | Runtime filtered but still in hardcoded list |

### Storage Layer (WalletDatabase.swift, SecureKeyStorage.swift)
| Control | Status | Notes |
|---------|--------|-------|
| SQLCipher encryption | ✅ PASS | AES-256-CBC, HMAC-SHA512, 256K iterations |
| Field-level encryption | ⚠️ PARTIAL | 5 fields encrypted, 6 remain plaintext |
| SQL injection | ✅ PASS | 100% parameterized queries |
| Thread safety | ⚠️ PARTIAL | FULLMUTEX active, but serial queue never used |
| Transactions | ⚠️ PARTIAL | Some ops transactional, many are not |
| Nullifier hashing | ✅ PASS | SHA256 before storage (VUL-009) |
| TX type obfuscation | ⚠️ PARTIAL | Substitution cipher, not real encryption |
| Spending key in DB | ❌ FAIL | Plaintext BLOB in accounts table |
| macOS key storage | ❌ FAIL | **CRITICAL** — Hardware UUID (publicly readable) = deterministic key extraction |
| iOS key storage | ✅ PASS | Secure Enclave with biometric |

### UI Layer (SettingsView.swift, SendView.swift, ContentView.swift)
| Control | Status | Notes |
|---------|--------|-------|
| Biometric auth (sends) | ✅ PASS | FIX #1273: fresh prompt, passcode fallback |
| Key export auth | ❌ FAIL | No auth before exporting spending key |
| Clipboard auto-clear | ❌ FAIL | 12+ files write with no auto-clear |
| Private key memory | ❌ FAIL | @State never cleared on dismissal |
| Address validation | ✅ PASS | FFI-based cryptographic validation |
| Fee validation | ✅ PASS | Prevents overflow, validated before send |
| Screenshot protection | ⚠️ PARTIAL | Background lock works, .inactive doesn't blur |
| PIN security | ❌ FAIL | Fixed salt, weak hashing, non-constant-time compare |
| TX race condition | ✅ PASS | Proper invalidation and validation |

---

## Safety Constraints

- **NEVER** kill any processes — this crashes the app
- **NEVER** change passwords without authorization
- **NEVER** run `kill` commands
- **NEVER** estimate dates or timelines
- **NEVER** modify or delete the boost file or database without explicit user approval
- **ALWAYS** test transaction building after ANY change to lib.rs
- **ALWAYS** test database reads after ANY change to WalletDatabase.swift
- **ALWAYS** verify Secure Enclave key retrieval after ANY change to SecureKeyStorage.swift
- **ALWAYS** back up the database before running migrations
- Rust FFI changes require recompilation of the library
- Database schema changes require migration logic
- PIN salt change requires migration of existing PINs

## Files Reference

| File | Lines | Layer | Tasks |
|------|-------|-------|-------|
| Libraries/zipherx-ffi/src/lib.rs | ~7,864 | Crypto/FFI | 3, 4, 5, 7, 8, 20 |
| Libraries/zipherx-ffi/src/download.rs | ~400 | Crypto/FFI | NEW-005 |
| Libraries/zipherx-ffi/src/tor.rs | ~1,600 | Crypto/FFI | (safe) |
| Libraries/zipherx-ffi/Cargo.toml | ~50 | Crypto/FFI | 8 |
| Sources/Core/Storage/WalletDatabase.swift | ~6,600+ | Storage | 1, 2, 15, 16, 19, 23 |
| Sources/Core/Storage/SecureKeyStorage.swift | ~700+ | Storage | 25 |
| Sources/Core/Storage/DatabaseEncryption.swift | ~230 | Storage | (secure) |
| Sources/Core/Storage/SQLCipherManager.swift | ~500+ | Storage | (secure) |
| Sources/Core/Network/Peer.swift | ~5,600+ | Network | 9, 10, 11, 22, 24 |
| Sources/Core/Network/NetworkManager.swift | ~8,000+ | Network | 13, 22, 24 |
| Sources/Core/Network/TorManager.swift | ~1,100+ | Network | (secure) |
| Sources/Features/Settings/SettingsView.swift | ~3,900+ | UI | 6, 14 |
| Sources/Features/Send/SendView.swift | ~1,800+ | UI | 12, 21 |
| Sources/Features/FullNodeWallet/FullNodeWalletView.swift | ~2,000+ | UI | NEW-003 |
| Sources/App/ContentView.swift | ~2,400+ | UI | 12, 17 |
| Sources/App/AppDelegate.swift | ~147 | UI | 17 |
| Sources/Core/Services/DebugLogger.swift | ~519 | Services | 18, NEW-001 |
| Sources/Core/Security/BiometricAuthManager.swift | ~400+ | Security | (secure) |
| Multiple UI files | Various | UI | 12, 18 |
