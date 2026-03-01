//! Utility function tests: version, branch IDs, fee, hashing
//!
//! All parallel-safe — no global state modification.

mod common;
use common::*;

extern crate zipherx_ffi;

// ═══════════════════════════════════════════════════════════
// Version
// ═══════════════════════════════════════════════════════════

#[test]
fn version_is_3() {
    let v = zipherx_ffi::zipherx_version();
    assert_eq!(v, 3, "Library version must be 3");
}

// ═══════════════════════════════════════════════════════════
// Branch IDs
// ═══════════════════════════════════════════════════════════

#[test]
fn branch_id_buttercup_post_707000() {
    let bid = zipherx_ffi::zipherx_get_branch_id(2923000);
    assert_eq!(
        bid, BUTTERCUP_BRANCH_ID,
        "Height 2923000 must return Buttercup branch ID 0x{:08x}",
        BUTTERCUP_BRANCH_ID
    );
}

#[test]
fn branch_id_sapling_activation() {
    let bid = zipherx_ffi::zipherx_get_branch_id(476969);
    assert_ne!(bid, 0, "Sapling activation height must have non-zero branch ID");
}

#[test]
fn branch_id_pre_buttercup_differs() {
    let pre = zipherx_ffi::zipherx_get_branch_id(706999);
    let post = zipherx_ffi::zipherx_get_branch_id(707000);
    assert_ne!(
        pre, post,
        "Branch ID must change at Buttercup fork height 707000"
    );
}

// ═══════════════════════════════════════════════════════════
// Buttercup Support
// ═══════════════════════════════════════════════════════════

#[test]
fn buttercup_support_enabled() {
    assert!(
        zipherx_ffi::zipherx_verify_buttercup_support(),
        "Buttercup support must be enabled"
    );
}

// ═══════════════════════════════════════════════════════════
// Rayon Threads
// ═══════════════════════════════════════════════════════════

#[test]
fn rayon_threads_positive() {
    let threads = zipherx_ffi::zipherx_get_rayon_threads();
    assert!(threads >= 1, "Must have at least 1 rayon thread");
}

// ═══════════════════════════════════════════════════════════
// Double SHA256
// ═══════════════════════════════════════════════════════════

#[test]
fn double_sha256_known_vector() {
    // SHA256(SHA256("")) is a well-known constant
    // SHA256("") = e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
    // SHA256(above) = 5df6e0e2761359d30a8275058e299fcc0381534545f55cf43e41983f5d4c9456
    let hash = double_sha256(&[]).expect("double SHA256 of empty failed");
    assert_eq!(
        hex_encode(&hash),
        "5df6e0e2761359d30a8275058e299fcc0381534545f55cf43e41983f5d4c9456",
        "Double SHA256 of empty must match known vector"
    );
}

#[test]
fn double_sha256_deterministic() {
    let data = b"ZipherX test data";
    let h1 = double_sha256(data).expect("h1 failed");
    let h2 = double_sha256(data).expect("h2 failed");
    assert_eq!(h1, h2, "Same input must produce same hash");
}

#[test]
fn double_sha256_different_inputs() {
    let h1 = double_sha256(b"input1").unwrap();
    let h2 = double_sha256(b"input2").unwrap();
    assert_ne!(h1, h2, "Different inputs must produce different hashes");
}

// ═══════════════════════════════════════════════════════════
// Transaction Fee
// ═══════════════════════════════════════════════════════════

#[test]
fn set_fee_valid() {
    let result = zipherx_ffi::zipherx_set_transaction_fee(10000);
    assert_eq!(result, 1, "Setting 10000 fee must succeed (FFI_SUCCESS=1)");
    assert_eq!(
        zipherx_ffi::zipherx_get_transaction_fee(),
        10000,
        "Fee must be retrievable after setting"
    );
}

#[test]
fn set_fee_too_low() {
    let result = zipherx_ffi::zipherx_set_transaction_fee(100);
    assert_eq!(result, -6, "Fee 100 must fail (FFI_ERROR_INVALID_DATA=-6)");
}

#[test]
fn set_fee_too_high() {
    let result = zipherx_ffi::zipherx_set_transaction_fee(10_000_000);
    assert_eq!(result, -6, "Fee 10M must fail (FFI_ERROR_INVALID_DATA=-6)");
}
