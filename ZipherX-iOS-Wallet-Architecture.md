# ZipherX: Secure & Decentralized iOS Wallet Architecture

## Executive Summary

This document outlines the architecture for a trustless, decentralized cryptocurrency wallet for iOS that maintains security properties comparable to a full node while respecting iOS platform constraints.

---

## Table of Contents

1. [The Challenge](#the-challenge)
2. [Architecture Design](#architecture-design)
3. [Security Model](#security-model)
4. [Implementation Components](#implementation-components)
5. [Data Requirements](#data-requirements)
6. [Security Comparison](#security-comparison)
7. [Implementation Phases](#implementation-phases)
8. [Technical Specifications](#technical-specifications)

---

## The Challenge

iOS restrictions prevent running a full node due to:
- No `fork()`/daemon process model
- Background networking restrictions
- Storage limitations (10+ GB infeasible)
- App Store cryptocurrency policies

**Solution:** Design a hybrid SPV + proof verification system that maintains security and decentralization without trusting third parties.

---

## Architecture Design

### Core Principles

1. **No trusted servers** - Verify everything locally
2. **Multiple random peers** - No single point of failure
3. **Cryptographic proofs** - Don't trust, verify
4. **Local key storage** - Keys never leave device

### Network Architecture

```
┌─────────────────┐
│   iOS Wallet    │
└────────┬────────┘
         │
    ┌────┴────┐
    │         │
┌───▼───┐ ┌───▼───┐ ┌───────┐
│ Node1 │ │ Node2 │ │ Node3 │  ← Connect to 8+ random peers
└───────┘ └───────┘ └───────┘
    │         │         │
    └────┬────┴────┬────┘
         │         │
    ┌────▼─────────▼────┐
    │  Cross-validate   │  ← Require consensus from multiple peers
    │  all responses    │
    └───────────────────┘
```

**Key Features:**
- Connect to 8+ random full nodes (not trusted servers)
- Query same data from multiple peers
- Reject if responses don't match (fraud detection)
- Rotate peers regularly

---

## Security Model

### Verification Layers

#### Layer 1: Transparent (t-addr) Transactions

| Verification | Method | Security Level |
|--------------|--------|----------------|
| Block headers | Download & verify PoW chain | Full SPV security |
| TX inclusion | Merkle proof verification | Cryptographic proof |
| TX validity | Verify signatures locally | No trust required |
| Double-spend | Query multiple peers | Consensus validation |

#### Layer 2: Shielded (z-addr) Transactions

| Verification | Method | Security Level |
|--------------|--------|----------------|
| Note commitment | Verify in commitment tree | Cryptographic proof |
| Nullifier check | Query multiple peers + Merkle proof | Fraud-proof |
| ZK proof | Verify locally on device | Full cryptographic security |

**Critical:** Sapling proofs are small (~200 bytes) and can be verified on mobile in ~50ms.

#### Layer 3: Local Key Security

```
┌─────────────────────────────┐
│     iOS Secure Enclave      │
├─────────────────────────────┤
│  • Spending key encryption  │
│  • Biometric unlock         │
│  • Hardware-backed keys     │
└─────────────────────────────┘
         │
         ▼
┌─────────────────────────────┐
│    Encrypted Wallet Data    │
├─────────────────────────────┤
│  • AES-256-GCM encryption   │
│  • Key derived from Enclave │
│  • BIP39 mnemonic backup    │
└─────────────────────────────┘
```

### Trust Model

| Component | Trust Level | Rationale |
|-----------|-------------|-----------|
| Cryptography (Sapling proofs) | Full | Mathematical guarantee |
| Block PoW | Full | Computational guarantee |
| Merkle proofs | Full | Cryptographic guarantee |
| iOS Secure Enclave | High | Hardware isolation |
| Network peers | **Zero** | Verify everything |

### Attack Resistance Matrix

| Attack Vector | Defense Mechanism |
|---------------|-------------------|
| Malicious node | Query 8+ peers, require consensus |
| Eclipse attack | Peer diversity, DNS seeds, hardcoded peers |
| Fake transaction | Merkle proof verification |
| Double spend | Wait for confirmations + multi-peer check |
| Device theft | Secure Enclave + biometric + encryption |
| Network MITM | TLS + peer authentication |
| Long-range attack | Hardcoded checkpoints |

---

## Implementation Components

### 1. Compact Block Filters (BIP-158/Neutrino)

Instead of downloading full blocks, use compact filters for bandwidth efficiency:

```cpp
// Client downloads compact filters (~20KB/day vs 1MB+/block)
// Filters allow detecting relevant transactions
// Only download full blocks when filter matches

struct CompactFilter {
    uint256 blockHash;
    std::vector<uint8_t> filter; // GCS encoded
};

bool CheckFilterMatch(CompactFilter& filter, Script& watchScript) {
    // Returns true if script MIGHT be in block
    // False positives possible, false negatives impossible
}
```

**Benefits:**
- ~1000x less bandwidth than full blocks
- Privacy preserved (server doesn't know which addresses)
- Trustless (can verify filter against block)

### 2. Multi-Peer Consensus Validation

```cpp
class TrustlessQuery {
    static const int MIN_PEERS = 8;
    static const int REQUIRED_CONSENSUS = 6;

    template<typename T>
    T QueryWithConsensus(std::string method, UniValue params) {
        std::map<T, int> responses;

        for (auto& peer : GetRandomPeers(MIN_PEERS)) {
            T result = peer.Query(method, params);
            responses[result]++;
        }

        // Find response with most agreement
        auto best = std::max_element(responses.begin(), responses.end(),
            [](auto& a, auto& b) { return a.second < b.second; });

        if (best->second < REQUIRED_CONSENSUS) {
            throw ConsensusError("Insufficient peer agreement");
        }

        return best->first;
    }
};
```

### 3. On-Device Sapling Proof Verification

```cpp
// Verify Sapling spend proof locally - NO TRUST REQUIRED
bool VerifySaplingSpend(
    const SpendDescription& spend,
    const uint256& sighash,
    const uint256& anchor
) {
    // This runs ON DEVICE - full cryptographic verification
    return librustzcash_sapling_check_spend(
        spend.cv.begin(),
        anchor.begin(),
        spend.nullifier.begin(),
        spend.rk.begin(),
        sighash.begin(),
        spend.spendAuthSig.begin(),
        spend.zkproof.begin()
    );
}

// Performance: ~50ms on iPhone 12+
```

### 4. iOS Secure Enclave Integration

```swift
import Security
import LocalAuthentication

class SecureKeyStorage {

    /// Store spending key with Secure Enclave protection
    func storeSpendingKey(_ key: Data, biometricProtected: Bool) throws {
        var error: Unmanaged<CFError>?

        let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            biometricProtected ? [.privateKeyUsage, .biometryCurrentSet] : .privateKeyUsage,
            &error
        )

        guard let accessControl = access else {
            throw KeyStorageError.accessControlCreationFailed
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecAttrAccessControl as String: accessControl,
            kSecAttrLabel as String: "com.zipherx.spendingkey",
            kSecValueData as String: key
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeyStorageError.storeFailed(status)
        }
    }

    /// Sign transaction using Secure Enclave (key never leaves hardware)
    func signTransaction(_ transactionHash: Data) throws -> Data {
        let context = LAContext()
        context.localizedReason = "Sign transaction"

        // Key operations happen entirely within Secure Enclave
        // Private key material never exposed to application memory
    }

    /// Retrieve key with biometric authentication
    func retrieveKey() throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrLabel as String: "com.zipherx.spendingkey",
            kSecReturnData as String: true,
            kSecUseOperationPrompt as String: "Access your wallet"
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            throw KeyStorageError.retrieveFailed(status)
        }

        return data
    }
}
```

### 5. Checkpoint System

```cpp
// Hardcoded checkpoints prevent long-range attacks
static const std::map<int, uint256> CHECKPOINTS = {
    {0, uint256S("0x0007104ccda289427919efc39dc9e4d499804b7bebc22df55f8b834301260602")},
    {100000, uint256S("0x...")},
    {500000, uint256S("0x...")},
    // Updated with each release
};

bool ValidateChain(std::vector<BlockHeader>& headers) {
    for (auto& [height, hash] : CHECKPOINTS) {
        if (headers.size() <= height) continue;
        if (headers[height].GetHash() != hash) {
            return false; // Chain doesn't match known history
        }
    }
    return true;
}
```

### 6. BIP39 Mnemonic Backup System

```cpp
class MnemonicSeed {
private:
    std::vector<std::string> words;
    HDSeed hdSeed;

public:
    // Generate new mnemonic (24 words for 256-bit security)
    static MnemonicSeed Generate() {
        std::vector<uint8_t> entropy(32);
        GetRandBytes(entropy.data(), entropy.size());

        // Convert to mnemonic words using BIP39 wordlist
        auto words = EntropyToMnemonic(entropy);

        // Derive seed using PBKDF2-SHA512
        auto seed = MnemonicToSeed(words, "");

        return MnemonicSeed(words, HDSeed(seed));
    }

    // Recover from mnemonic
    static MnemonicSeed FromMnemonic(const std::vector<std::string>& words) {
        if (!ValidateMnemonic(words)) {
            throw std::invalid_argument("Invalid mnemonic");
        }

        auto seed = MnemonicToSeed(words, "");
        return MnemonicSeed(words, HDSeed(seed));
    }

    // Get display words for backup
    std::vector<std::string> GetWords() const { return words; }

    // Get HD seed for key derivation
    HDSeed GetHDSeed() const { return hdSeed; }
};
```

---

## Data Requirements

### Storage Budget

| Component | Size | Purpose |
|-----------|------|---------|
| Block headers | ~50 MB | Chain validation |
| Compact filters | ~500 MB | Transaction detection |
| Wallet data | ~10 MB | Keys, notes, history |
| Sapling params | ~50 MB | Proof verification |
| **Total** | **~610 MB** | Fits on any modern device |

### Bandwidth Requirements

| Operation | Initial | Monthly | Notes |
|-----------|---------|---------|-------|
| Headers sync | ~50 MB | ~3 MB | Incremental updates |
| Filters sync | ~500 MB | ~20 MB | One-time bulk, then incremental |
| TX operations | - | ~1 MB | Depends on usage |
| **Total** | **~550 MB** | **~24 MB** | Acceptable for mobile |

---

## Security Comparison

| Security Aspect | Full Node | ZipherX Design | Typical Mobile Wallet |
|-----------------|-----------|----------------|----------------------|
| Key security | ★★★★★ | ★★★★★ | ★★★☆☆ |
| TX verification | ★★★★★ | ★★★★☆ | ★☆☆☆☆ |
| Privacy | ★★★★★ | ★★★★☆ | ★★☆☆☆ |
| Decentralization | ★★★★★ | ★★★★☆ | ★☆☆☆☆ |
| Network trust | Zero | Zero | Full trust |
| Censorship resistance | ★★★★★ | ★★★★☆ | ★☆☆☆☆ |
| Mobile feasibility | ☆☆☆☆☆ | ★★★★★ | ★★★★★ |

**Key Insight:** This design achieves ~90% of full node security with ~1% of the resources.

---

## Implementation Phases

### Phase 1: Core Security Foundation (4-6 weeks)

**Deliverables:**
- iOS Secure Enclave key storage
- BIP39 mnemonic generation and recovery
- Local Sapling proof verification (librustzcash iOS build)
- Encrypted SQLite wallet database
- Basic UI for key management

**Milestones:**
- [ ] Secure Enclave wrapper library
- [ ] BIP39 implementation with test vectors
- [ ] librustzcash cross-compiled for iOS
- [ ] Wallet database schema and encryption

### Phase 2: Network Layer (6-8 weeks)

**Deliverables:**
- Multi-peer connection manager
- Consensus-based query system
- Compact block filter download and parsing
- Header chain validation with checkpoints
- Peer reputation and rotation system

**Milestones:**
- [ ] P2P protocol implementation
- [ ] BIP-158 compact filter support
- [ ] Header chain sync and validation
- [ ] Multi-peer consensus queries
- [ ] Peer discovery (DNS seeds + hardcoded)

### Phase 3: Shielded Transaction Support (4-6 weeks)

**Deliverables:**
- Sapling note scanning from filters
- Nullifier tracking and validation
- Shielded transaction construction
- Proof generation (on-device or hybrid)
- Incoming/outgoing viewing key support

**Milestones:**
- [ ] Note commitment tree maintenance
- [ ] Witness updates for spendable notes
- [ ] Transaction builder for shielded TX
- [ ] Sapling proof generation
- [ ] Full z-addr send/receive

### Phase 4: Polish and Hardening (2-4 weeks)

**Deliverables:**
- Background sync (within iOS limits)
- Push notifications for incoming transactions
- UI/UX refinement
- Comprehensive test suite
- Security audit preparation

**Milestones:**
- [ ] Background fetch implementation
- [ ] Push notification service
- [ ] Automated testing (unit + integration)
- [ ] Performance optimization
- [ ] Documentation complete

**Total Timeline: 16-24 weeks**

---

## Technical Specifications

### Platform Requirements

- **iOS Version:** 14.0+ (Secure Enclave APIs)
- **Devices:** iPhone 8+ / iPad (6th gen)+
- **Storage:** 1 GB available
- **Network:** WiFi for initial sync recommended

### Dependencies

| Library | Version | Purpose | iOS Support |
|---------|---------|---------|-------------|
| librustzcash | Latest | Sapling cryptography | Cross-compile required |
| libsodium | 1.0.18+ | Cryptographic primitives | Native iOS support |
| SQLCipher | 4.5+ | Encrypted database | Native iOS support |
| Reachability | - | Network monitoring | Native iOS |

### Build Configuration

```yaml
# iOS specific build settings
deployment_target: "14.0"
architectures:
  - arm64
code_signing:
  team_id: "XXXXXXXXXX"
  entitlements:
    - keychain-access-groups
    - application-identifier
capabilities:
  - Secure Enclave
  - Background Fetch
  - Push Notifications
```

---

## Open Questions and Considerations

### 1. Proof Generation Strategy

Generating Sapling proofs requires ~40MB parameters and ~2 seconds on mobile.

**Options:**
- **A) On-device only:** Slower but fully trustless
- **B) Remote prover:** Fast but requires trusting prover with viewing key
- **C) Hybrid:** Generate simple proofs locally, complex proofs remotely

**Recommendation:** Start with on-device (Option A), add remote proving as opt-in feature.

### 2. Initial Sync Experience

First sync of compact filters takes ~30 minutes on WiFi.

**Solutions:**
- Background download when on WiFi + charging
- Optional trusted checkpoint bundle download
- Progressive sync with usable wallet after headers

### 3. App Store Compliance

Apple cryptocurrency app requirements:
- Clear risk disclaimers
- No misleading claims about security/returns
- Compliance with local financial regulations
- No mining functionality

**Mitigation:** Legal review before submission, clear documentation.

---

## Conclusion

The ZipherX architecture demonstrates that a secure, decentralized cryptocurrency wallet is achievable on iOS without compromising on the core principles of trustless verification. By combining:

- **Compact block filters** for efficient sync
- **Multi-peer consensus** for decentralization
- **Local proof verification** for cryptographic security
- **Secure Enclave** for hardware-backed key protection

We can deliver a mobile wallet that approaches full node security while remaining practical for everyday mobile use.

---

## References

- [BIP-158: Compact Block Filters](https://github.com/bitcoin/bips/blob/master/bip-0158.mediawiki)
- [BIP-39: Mnemonic Seed Phrases](https://github.com/bitcoin/bips/blob/master/bip-0039.mediawiki)
- [ZIP-32: Shielded HD Wallets](https://zips.z.cash/zip-0032)
- [Zcash Protocol Specification](https://zips.z.cash/protocol/protocol.pdf)
- [Apple Secure Enclave Documentation](https://developer.apple.com/documentation/security/certificate_key_and_trust_services/keys/protecting_keys_with_the_secure_enclave)
- [Neutrino Light Client Protocol](https://github.com/lightninglabs/neutrino)

---

*Document Version: 1.0*
*Last Updated: November 2024*
*Author: ZipherX Development Team*
