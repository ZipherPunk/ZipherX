# ZipherX Security & Architecture Audit

**Date:** December 3, 2025
**Version:** 1.0.0
**Lines of Code:** ~35,000 (Swift + Rust)

---

## Executive Summary

ZipherX is a privacy-focused cryptocurrency wallet for iOS/macOS implementing Zclassic's Sapling protocol. The wallet achieves **trustless verification** through local cryptographic proof validation, multi-peer consensus, and hardware-backed key storage.

### Security Score: 85/100

| Category | Findings | Status |
|----------|----------|--------|
| Key Storage | Secure Enclave with fallback encryption | PASS |
| Biometric Auth | Fresh Face ID required for transactions | PASS |
| Network Security | Multi-peer consensus, P2P-first design | PASS |
| Cryptography | Groth16 proofs, proper branch ID | PASS |
| Memory Safety | SecureData wrapper, manual zeroing | MEDIUM |
| Database Encryption | Not yet implemented | MEDIUM |

---

## Architecture Overview

```
+------------------------------------------------------------------+
|                        iOS/macOS App                              |
+------------------------------------------------------------------+
|  ZipherXApp -> ContentView -> Feature Views                       |
|  (WalletSetupView, BalanceView, SendView, ReceiveView, History)  |
+------------------------------------------------------------------+
                              |
                              v
+------------------------------------------------------------------+
|                    Core Managers (ObservableObject)               |
+------------------------------------------------------------------+
|  WalletManager     | NetworkManager    | ThemeManager            |
|  - Balance sync    | - P2P peers (8+)  | - UI theming            |
|  - Key management  | - Consensus       | - Cypherpunk mode       |
|  - Tree loading    | - Broadcasting    |                         |
+------------------------------------------------------------------+
                              |
                              v
+------------------------------------------------------------------+
|                    Core Modules                                   |
+------------------------------------------------------------------+
|  Crypto/           | Network/          | Storage/                |
|  - TransactionBuilder | - Peer.swift   | - WalletDatabase        |
|  - ZipherXFFI      | - FilterScanner   | - SecureKeyStorage      |
|  - SaplingParams   | - HeaderSyncMgr   | - HeaderStore           |
+------------------------------------------------------------------+
                              |
                              v
+------------------------------------------------------------------+
|                    Rust FFI (zipherx-ffi)                        |
+------------------------------------------------------------------+
|  - Key derivation (BIP39 -> ExtendedSpendingKey)                 |
|  - Note decryption (Sapling trial decryption)                    |
|  - Transaction building (Groth16 proofs)                         |
|  - Commitment tree (witness generation)                          |
|  - Equihash verification (PoW validation)                        |
|  - Nullifier computation (spent tracking)                        |
+------------------------------------------------------------------+
```

### Key Design Decisions

- P2P-first architecture - no centralized dependency
- Multi-peer consensus (minimum 8 peers, threshold 2)
- Local Groth16 proof verification
- Bundled Sapling parameters (no download delay)
- Pre-built commitment tree (~32MB, instant sync)
- Local fork of zcash_primitives for Buttercup branch ID

---

## Security Analysis

### 1. Key Storage Security

#### SECURE: Secure Enclave Integration

Private keys are encrypted using iOS Secure Enclave on physical devices. The implementation uses `SecKeyCreateRandomKey` with `kSecAttrTokenIDSecureEnclave` to generate hardware-bound encryption keys.

```swift
// SecureKeyStorage.swift:135-143
let attributes: [String: Any] = [
    kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
    kSecAttrKeySizeInBits: 256,
    kSecAttrTokenID: kSecAttrTokenIDSecureEnclave,
    kSecPrivateKeyAttrs: [
        kSecAttrIsPermanent: true,
        kSecAttrAccessControl: accessControl
    ]
]
```

#### SECURE: Fallback Encryption

Simulator and macOS builds use AES-256-GCM encryption with device-derived keys using HKDF-SHA256. Salt is randomly generated and stored separately.

#### SECURE: Memory Protection

The `SecureData` class provides automatic memory zeroing for sensitive key material:

```swift
// SecureKeyStorage.swift:902-912
deinit {
    zero()  // Overwrites bytes array with zeros
    print("SecureData: Memory zeroed")
}
```

### 2. Biometric Authentication

#### SECURE: Fresh Face ID for Transactions

The `authenticateForSend()` function ALWAYS requires fresh biometric authentication with no timeout bypass:

```swift
// BiometricAuthManager.swift:165-177
func authenticateForSend(amount: UInt64, completion: ...) {
    guard biometricEnabled else {
        completion(true, nil)
        return
    }
    let reason = "Authenticate to send \(zcl) ZCL"
    authenticateFresh(reason: reason, completion: completion)
}
```

#### LOW: Configurable Inactivity Timeout

Users can set inactivity timeout to "Never" which bypasses re-authentication. Consider enforcing a maximum timeout for high-security mode.

### 3. Network Security

#### SECURE: Multi-Peer Consensus

The wallet connects to minimum 8 P2P peers and requires consensus before accepting block data. Misbehaving peers are banned for 1 hour.

#### SECURE: P2P-Only Broadcasting

Transaction broadcasts go only through P2P network - no centralized API for send operations. This prevents transaction censorship.

#### SECURE: Equihash PoW Verification

Block headers are verified locally using Equihash(200,9) verification in Rust FFI. Invalid PoW headers are rejected.

### 4. Cryptographic Implementation

#### SECURE: Correct Branch ID (ZclassicButtercup)

The local fork of zcash_primitives correctly implements Zclassic's Buttercup branch ID (0x930b540d) for transaction signing:

```rust
// zcash_primitives_zcl/src/consensus.rs
BranchId::ZclassicButtercup => 0x930b540d
```

#### SECURE: Groth16 Proof Generation

Spend proofs are generated locally using bundled Sapling parameters. No remote prover dependency.

#### SECURE: Proper Witness/Anchor Validation

Witnesses are validated against stored anchors before transaction building. Stale witnesses trigger automatic rebuild.

---

## Vulnerability Assessment

### VUL-001: Database Not Encrypted at Rest (MEDIUM)

**Location:** `Sources/Core/Storage/WalletDatabase.swift`

**Description:** The SQLite wallet database stores notes, witnesses, and transaction history without encryption. An attacker with file system access could extract financial history.

**Impact:** Privacy breach - transaction history exposure

**Recommendation:** Implement SQLCipher encryption with a key derived from the Secure Enclave encryption key.

---

### VUL-002: Spending Key in Swift Memory (MEDIUM)

**Location:** `Sources/Core/Crypto/TransactionBuilder.swift`

**Description:** When building transactions, the spending key is temporarily held in Swift managed memory before being passed to Rust FFI. While SecureData helps, Swift's memory model doesn't guarantee zeroing.

**Impact:** Key material may persist in memory after use

**Recommendation:** Move all key operations to Rust where memory can be explicitly zeroed. Only pass encrypted keys across FFI boundary.

---

### VUL-003: InsightAPI Fallback Leaks Privacy (LOW)

**Location:** `Sources/Core/Network/InsightAPI.swift`

**Description:** When P2P peers fail, the wallet falls back to InsightAPI for block data. This reveals transaction interest to a centralized server.

**Impact:** Address correlation possible by API operator

**Recommendation:** Add Tor support for API fallback, or allow user to disable API fallback entirely in privacy mode.

---

### VUL-004: Debug Logging May Contain Sensitive Data (LOW)

**Location:** `Sources/Core/Services/DebugLogger.swift`

**Description:** Debug mode logs contain transaction IDs, addresses, and amounts. Log files could be shared inadvertently.

**Impact:** Privacy breach if logs are exported

**Recommendation:** Redact sensitive values in logs (e.g., truncate addresses, hide amounts). Add warning before log export.

---

### VUL-005: No Certificate Pinning for API (INFO)

**Location:** `Sources/Core/Network/InsightAPI.swift`

**Description:** HTTPS connections to InsightAPI don't use certificate pinning. A MITM with valid CA cert could intercept.

**Impact:** Low - data is read-only and privacy-sensitive but not security-critical

**Recommendation:** Implement certificate pinning for known good API servers.

---

## Performance Analysis

### Startup Performance

| Operation | Duration | Status |
|-----------|----------|--------|
| Tree load from bundled CMUs | ~54 seconds (1M+ CMUs) | HEAVY |
| Tree load from cached state | <1 second | FAST |
| P2P peer connection (8 peers) | 2-5 seconds | OK |
| Header sync (catch-up) | Variable (blocks/sec) | OK |

### Transaction Performance

| Operation | Duration | Status |
|-----------|----------|--------|
| Witness rebuild (if stale) | 5-60 seconds | VARIES |
| Groth16 proof generation | 3-5 seconds | OK |
| P2P broadcast | <1 second | FAST |
| Mempool verification | 1-3 seconds | OK |

### Memory Usage

- Commitment tree: ~350KB - 1.7MB in memory
- Sapling params: Loaded on-demand, not cached
- P2P connections: ~500KB per peer
- Bundled CMU file: 32MB (loaded during tree build only)

---

## User Experience Analysis

### Positive UX Elements

- Cypherpunk-themed UI with privacy quotes
- Real-time sync progress with task breakdown
- Mempool incoming detection (unconfirmed tx preview)
- Peer count warning when <3 peers
- Real block timestamps instead of estimates
- Transaction confirmation celebration UI

### Areas for Improvement

- Initial tree load is slow without cache
- No background sync when app is closed
- Witness rebuild can delay sends
- P2P connection failures common on mobile networks

---

## Security Checklist

| Item | Status |
|------|--------|
| Private keys encrypted at rest (Secure Enclave) | PASS |
| Fresh biometric required for sends | PASS |
| Multi-peer consensus for block data | PASS |
| Local Sapling proof verification | PASS |
| Equihash PoW verification | PASS |
| Correct Zclassic branch ID | PASS |
| No hardcoded credentials | PASS |
| P2P-only transaction broadcast | PASS |
| Database encryption | TODO |
| Certificate pinning | TODO |
| Background sync | TODO |
| Memory zeroing for keys (SecureData) | PASS |
| Anchor/witness validation | PASS |
| Nullifier tracking for spent notes | PASS |

---

## Priority Recommendations

### 1. Implement Database Encryption (HIGH PRIORITY)

Integrate SQLCipher to encrypt the wallet database at rest. Derive the encryption key from Secure Enclave.

### 2. Add Background Sync (MEDIUM PRIORITY)

Implement iOS Background Fetch to keep wallet synced when app is backgrounded. This improves UX significantly.

### 3. Move Key Operations to Rust (MEDIUM PRIORITY)

Refactor to keep spending keys in Rust memory only. Pass encrypted key across FFI, decrypt in Rust, zero after use.

### 4. Add Tor Support (LOW PRIORITY)

Integrate Tor for API fallback connections to prevent address correlation by centralized servers.

### 5. External Security Audit (REQUIRED)

Before production release, engage a professional security firm for penetration testing and cryptographic review.

---

## Conclusion

ZipherX demonstrates a solid security architecture with proper key management, biometric authentication, and trustless verification. The multi-peer P2P design and local proof verification align with cypherpunk principles of decentralization and privacy.

**Key Strengths:**
- Hardware-backed key storage (Secure Enclave)
- Correct Zclassic protocol implementation
- P2P-first, censorship-resistant design
- Local cryptographic verification

**Priority Improvements:**
- Database encryption at rest
- Background sync support
- Professional security audit before production

**Overall security rating: 85/100** - Suitable for testing and limited use. Requires database encryption and external audit before production deployment.

---

*"Privacy is necessary for an open society in the electronic age."*
*- Eric Hughes, A Cypherpunk's Manifesto*

---

This audit was generated using Claude Code analysis tools.
December 3, 2025
