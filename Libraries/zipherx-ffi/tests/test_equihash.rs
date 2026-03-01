//! Equihash verification tests with real Zclassic block data
//!
//! All parallel-safe — pure cryptographic verification, no global state.

mod common;
use common::*;

/// Parse block 2926123 into its components
fn parse_block_2926123() -> (Vec<u8>, Vec<u8>) {
    let raw = hex_decode(BLOCK_2926123_HEX);
    assert_eq!(raw.len(), 543, "Block 2926123 should be 543 bytes");

    let header = raw[0..140].to_vec();
    let (solution_len, varint_size) = parse_varint(&raw[140..]);
    assert_eq!(solution_len, 400, "Post-Bubbles solution must be 400 bytes");

    let solution_start = 140 + varint_size;
    let solution = raw[solution_start..solution_start + solution_len].to_vec();

    (header, solution)
}

#[test]
fn verify_equihash_192_7_valid() {
    let (header, solution) = parse_block_2926123();
    assert!(
        verify_equihash(&header, &solution),
        "Block 2926123 must pass Equihash(192,7) verification"
    );
}

#[test]
fn verify_equihash_invalid_solution() {
    let (header, _) = parse_block_2926123();
    let bad_solution = vec![0u8; 400]; // All zeros = invalid
    assert!(
        !verify_equihash(&header, &bad_solution),
        "All-zero solution must fail"
    );
}

#[test]
fn verify_equihash_wrong_solution_length() {
    let (header, _) = parse_block_2926123();
    let wrong_len_solution = vec![0u8; 500]; // Neither 400 nor 1344
    assert!(
        !verify_equihash(&header, &wrong_len_solution),
        "500-byte solution must fail"
    );
}

#[test]
fn compute_block_hash_deterministic() {
    let (header, solution) = parse_block_2926123();

    let hash1 = compute_block_hash(&header, &solution).expect("hash1 failed");
    let hash2 = compute_block_hash(&header, &solution).expect("hash2 failed");

    assert_eq!(hash1, hash2, "Same input must produce same hash");
    assert_ne!(hash1, [0u8; 32], "Block hash must not be all zeros");
}

#[test]
fn compute_block_hash_nonzero() {
    let (header, solution) = parse_block_2926123();
    let hash = compute_block_hash(&header, &solution).expect("hash failed");

    // The hash should be non-trivial
    let sum: u64 = hash.iter().map(|&b| b as u64).sum();
    assert!(sum > 0, "Block hash must have non-zero bytes");
}
