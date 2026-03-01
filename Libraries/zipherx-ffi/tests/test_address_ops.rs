//! Address encoding/decoding/validation tests
//!
//! All parallel-safe — no global state modification.

mod common;
use common::*;

#[test]
fn validate_known_address() {
    assert!(
        validate_address(KNOWN_VALID_ADDRESS),
        "Known z-address must validate"
    );
}

#[test]
fn validate_address_empty() {
    assert!(!validate_address(""), "Empty string must fail");
}

#[test]
fn validate_address_truncated() {
    assert!(
        !validate_address("zs1rvcpa07m7"),
        "Truncated address must fail"
    );
}

#[test]
fn validate_address_gibberish() {
    assert!(
        !validate_address("notanaddressatall"),
        "Gibberish must fail"
    );
}

#[test]
fn encode_address_starts_with_zs() {
    let seed = [0u8; 64];
    let sk = derive_spending_key(&seed, 0).unwrap();
    let (addr_bytes, _) = derive_address(&sk, 0).unwrap();
    let encoded = encode_address(&addr_bytes).expect("encode failed");
    assert!(
        encoded.starts_with("zs1"),
        "Encoded address must start with 'zs1', got: {}",
        &encoded[..6]
    );
}

#[test]
fn decode_known_address() {
    let decoded = decode_address(KNOWN_VALID_ADDRESS);
    assert!(decoded.is_some(), "Known address must decode");
    let bytes = decoded.unwrap();
    assert_eq!(bytes.len(), 43);
}

#[test]
fn decode_encode_roundtrip() {
    let decoded = decode_address(KNOWN_VALID_ADDRESS).expect("decode failed");
    let re_encoded = encode_address(&decoded).expect("re-encode failed");
    assert_eq!(
        re_encoded, KNOWN_VALID_ADDRESS,
        "Round-trip must produce original address"
    );
}

#[test]
fn encode_decode_from_derived() {
    let seed = [0u8; 64];
    let sk = derive_spending_key(&seed, 0).unwrap();
    let (addr_bytes, _) = derive_address(&sk, 0).unwrap();

    let encoded = encode_address(&addr_bytes).expect("encode failed");
    let decoded = decode_address(&encoded).expect("decode failed");
    assert_eq!(
        addr_bytes, decoded,
        "encode → decode must return original bytes"
    );
}

#[test]
fn decode_invalid_bech32() {
    assert!(
        decode_address("notbech32atall").is_none(),
        "Invalid bech32 must return None"
    );
}
