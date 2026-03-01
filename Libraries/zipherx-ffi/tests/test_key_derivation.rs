//! Key derivation tests: mnemonic, seed, spending key, address, IVK, OVK
//!
//! All parallel-safe — no global state modification.

mod common;
use common::*;

// ═══════════════════════════════════════════════════════════
// Mnemonic Generation
// ═══════════════════════════════════════════════════════════

#[test]
fn generate_mnemonic_returns_24_words() {
    let phrase = generate_mnemonic().expect("mnemonic generation failed");
    let word_count = phrase.split_whitespace().count();
    assert_eq!(word_count, 24, "Expected 24 words, got {}", word_count);
}

#[test]
fn generate_mnemonic_is_valid() {
    let phrase = generate_mnemonic().expect("mnemonic generation failed");
    assert!(
        validate_mnemonic(&phrase),
        "Generated mnemonic should be valid"
    );
}

#[test]
fn generate_mnemonic_unique() {
    let m1 = generate_mnemonic().expect("first mnemonic failed");
    let m2 = generate_mnemonic().expect("second mnemonic failed");
    assert_ne!(m1, m2, "Two generated mnemonics must differ (entropy)");
}

// ═══════════════════════════════════════════════════════════
// Mnemonic Validation
// ═══════════════════════════════════════════════════════════

#[test]
fn validate_mnemonic_known_valid() {
    assert!(
        validate_mnemonic(KNOWN_VALID_MNEMONIC),
        "24x abandon + art should be valid"
    );
}

#[test]
fn validate_mnemonic_invalid_word() {
    let bad = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon zzzzzz";
    assert!(
        !validate_mnemonic(bad),
        "Invalid word 'zzzzzz' should fail"
    );
}

#[test]
fn validate_mnemonic_wrong_count() {
    assert!(
        !validate_mnemonic("abandon abandon abandon"),
        "3 words should fail"
    );
}

#[test]
fn validate_mnemonic_empty() {
    assert!(!validate_mnemonic(""), "Empty string should fail");
}

// ═══════════════════════════════════════════════════════════
// Seed Derivation
// ═══════════════════════════════════════════════════════════

#[test]
fn mnemonic_to_seed_deterministic() {
    let seed1 = mnemonic_to_seed(KNOWN_VALID_MNEMONIC).expect("seed1 failed");
    let seed2 = mnemonic_to_seed(KNOWN_VALID_MNEMONIC).expect("seed2 failed");
    assert_eq!(seed1, seed2, "Same mnemonic must produce same seed");
}

#[test]
fn mnemonic_to_seed_nonzero() {
    let seed = mnemonic_to_seed(KNOWN_VALID_MNEMONIC).expect("seed failed");
    assert_ne!(seed, [0u8; 64], "Seed must not be all zeros");
}

// ═══════════════════════════════════════════════════════════
// Spending Key Derivation
// ═══════════════════════════════════════════════════════════

#[test]
fn derive_spending_key_from_zero_seed() {
    let seed = [0u8; 64];
    let sk = derive_spending_key(&seed, 0).expect("key derivation failed");
    assert_eq!(sk.len(), 169);
}

#[test]
fn derive_spending_key_deterministic() {
    let seed = [0u8; 64];
    let sk1 = derive_spending_key(&seed, 0).expect("sk1 failed");
    let sk2 = derive_spending_key(&seed, 0).expect("sk2 failed");
    assert_eq!(sk1, sk2, "Same seed + account must produce same key");
}

#[test]
fn derive_spending_key_different_accounts() {
    let seed = [0u8; 64];
    let sk0 = derive_spending_key(&seed, 0).expect("account 0 failed");
    let sk1 = derive_spending_key(&seed, 1).expect("account 1 failed");
    assert_ne!(sk0, sk1, "Different accounts must produce different keys");
}

// ═══════════════════════════════════════════════════════════
// Address Derivation
// ═══════════════════════════════════════════════════════════

#[test]
fn derive_address_deterministic() {
    let seed = [0u8; 64];
    let sk = derive_spending_key(&seed, 0).unwrap();
    let (addr1, idx1) = derive_address(&sk, 0).expect("addr1 failed");
    let (addr2, idx2) = derive_address(&sk, 0).expect("addr2 failed");
    assert_eq!(addr1, addr2, "Same key + diversifier must produce same address");
    assert_eq!(idx1, idx2, "Actual diversifier index must be consistent");
}

#[test]
fn derive_address_different_diversifier() {
    let seed = [0u8; 64];
    let sk = derive_spending_key(&seed, 0).unwrap();
    let (addr0, _) = derive_address(&sk, 0).expect("div 0 failed");
    // Try several diversifier indices — not all are valid, but at least one should differ
    let mut found_different = false;
    for i in 1..100 {
        if let Some((addr_i, _)) = derive_address(&sk, i) {
            if addr_i != addr0 {
                found_different = true;
                break;
            }
        }
    }
    assert!(
        found_different,
        "Should find a different address with a different diversifier"
    );
}

// ═══════════════════════════════════════════════════════════
// IVK / OVK Derivation
// ═══════════════════════════════════════════════════════════

#[test]
fn derive_ivk_from_key() {
    let seed = [0u8; 64];
    let sk = derive_spending_key(&seed, 0).unwrap();
    let ivk = derive_ivk(&sk).expect("IVK derivation failed");
    assert_ne!(ivk, [0u8; 32], "IVK must be non-zero");
}

#[test]
fn derive_ivk_deterministic() {
    let seed = [0u8; 64];
    let sk = derive_spending_key(&seed, 0).unwrap();
    let ivk1 = derive_ivk(&sk).unwrap();
    let ivk2 = derive_ivk(&sk).unwrap();
    assert_eq!(ivk1, ivk2, "Same key must produce same IVK");
}

#[test]
fn derive_ovk_from_key() {
    let seed = [0u8; 64];
    let sk = derive_spending_key(&seed, 0).unwrap();
    let ovk = derive_ovk(&sk).expect("OVK derivation failed");
    assert_ne!(ovk, [0u8; 32], "OVK must be non-zero");
}

#[test]
fn derive_ovk_deterministic() {
    let seed = [0u8; 64];
    let sk = derive_spending_key(&seed, 0).unwrap();
    let ovk1 = derive_ovk(&sk).unwrap();
    let ovk2 = derive_ovk(&sk).unwrap();
    assert_eq!(ovk1, ovk2, "Same key must produce same OVK");
}

#[test]
fn ivk_and_ovk_are_different() {
    let seed = [0u8; 64];
    let sk = derive_spending_key(&seed, 0).unwrap();
    let ivk = derive_ivk(&sk).unwrap();
    let ovk = derive_ovk(&sk).unwrap();
    assert_ne!(ivk, ovk, "IVK and OVK must differ");
}

// ═══════════════════════════════════════════════════════════
// Full Derivation Chain
// ═══════════════════════════════════════════════════════════

#[test]
fn full_derivation_chain() {
    // mnemonic -> seed -> sk -> address -> encode -> validate
    let phrase = generate_mnemonic().expect("mnemonic failed");
    assert!(validate_mnemonic(&phrase));

    let seed = mnemonic_to_seed(&phrase).expect("seed failed");
    let sk = derive_spending_key(&seed, 0).expect("sk failed");
    let (addr_bytes, _) = derive_address(&sk, 0).expect("address failed");
    let addr_str = encode_address(&addr_bytes).expect("encode failed");

    assert!(addr_str.starts_with("zs1"), "Address must start with 'zs1'");
    assert!(validate_address(&addr_str), "Encoded address must validate");
}
