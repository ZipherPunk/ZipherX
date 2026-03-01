//! Spending key bech32 encoding/decoding tests
//!
//! All parallel-safe — no global state modification.

mod common;
use common::*;

#[test]
fn encode_spending_key_starts_with_prefix() {
    let seed = [0u8; 64];
    let sk = derive_spending_key(&seed, 0).unwrap();
    let encoded = encode_spending_key(&sk).expect("encode failed");
    assert!(
        encoded.starts_with("secret-extended-key-main1"),
        "Must start with 'secret-extended-key-main1', got: {}",
        &encoded[..30.min(encoded.len())]
    );
}

#[test]
fn encode_decode_spending_key_roundtrip() {
    let seed = [0u8; 64];
    let sk = derive_spending_key(&seed, 0).unwrap();
    let encoded = encode_spending_key(&sk).expect("encode failed");
    let decoded = decode_spending_key(&encoded).expect("decode failed");
    assert_eq!(sk, decoded, "Round-trip must produce original key");
}

#[test]
fn encode_spending_key_deterministic() {
    let seed = [0u8; 64];
    let sk = derive_spending_key(&seed, 0).unwrap();
    let e1 = encode_spending_key(&sk).unwrap();
    let e2 = encode_spending_key(&sk).unwrap();
    assert_eq!(e1, e2, "Same key must produce same encoding");
}

#[test]
fn decode_spending_key_invalid_prefix() {
    // Wrong HRP
    assert!(
        decode_spending_key("secret-extended-key-test1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq").is_none(),
        "Wrong network prefix must fail"
    );
}

#[test]
fn decode_spending_key_truncated() {
    assert!(
        decode_spending_key("secret-extended-key-main1qqqq").is_none(),
        "Truncated key must fail"
    );
}
