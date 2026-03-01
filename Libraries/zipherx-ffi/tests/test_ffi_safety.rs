//! FFI safety tests: null pointer handling, invalid inputs, boundary conditions
//!
//! Verifies that all FFI functions handle bad inputs gracefully without crashing.
//! All parallel-safe unless noted.

extern crate zipherx_ffi;

mod common;

use serial_test::serial;

// ═══════════════════════════════════════════════════════════
// Null Pointer: Key Derivation
// ═══════════════════════════════════════════════════════════

#[test]
fn null_generate_mnemonic() {
    let len = unsafe { zipherx_ffi::zipherx_generate_mnemonic(std::ptr::null_mut()) };
    assert_eq!(len, 0, "Null output must return 0");
}

#[test]
fn null_derive_spending_key_seed() {
    let mut sk = [0u8; 169];
    let ok = unsafe {
        zipherx_ffi::zipherx_derive_spending_key(std::ptr::null(), 0, sk.as_mut_ptr())
    };
    assert!(!ok, "Null seed must return false");
}

#[test]
fn null_derive_spending_key_output() {
    let seed = [0u8; 64];
    let ok = unsafe {
        zipherx_ffi::zipherx_derive_spending_key(seed.as_ptr(), 0, std::ptr::null_mut())
    };
    assert!(!ok, "Null output must return false");
}

#[test]
fn null_derive_address() {
    let ok = unsafe {
        zipherx_ffi::zipherx_derive_address(
            std::ptr::null(),
            0,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
        )
    };
    assert!(!ok, "All-null derive_address must return false");
}

#[test]
fn null_derive_ivk() {
    let mut ivk = [0u8; 32];
    let ok = unsafe { zipherx_ffi::zipherx_derive_ivk(std::ptr::null(), ivk.as_mut_ptr()) };
    assert!(!ok, "Null SK for IVK must return false");
}

#[test]
fn null_derive_ovk() {
    let mut ovk = [0u8; 32];
    let ok = unsafe { zipherx_ffi::zipherx_derive_ovk(std::ptr::null(), ovk.as_mut_ptr()) };
    assert!(!ok, "Null SK for OVK must return false");
}

// ═══════════════════════════════════════════════════════════
// Null Pointer: Address
// ═══════════════════════════════════════════════════════════

#[test]
fn null_encode_address() {
    let len = unsafe { zipherx_ffi::zipherx_encode_address(std::ptr::null(), std::ptr::null_mut()) };
    assert_eq!(len, 0, "Null encode_address must return 0");
}

#[test]
fn null_decode_address() {
    let ok = unsafe {
        zipherx_ffi::zipherx_decode_address(std::ptr::null(), std::ptr::null_mut())
    };
    assert!(!ok, "Null decode_address must return false");
}

// ═══════════════════════════════════════════════════════════
// Null Pointer: Tree Operations
// ═══════════════════════════════════════════════════════════

#[test]
#[serial]
fn null_tree_root() {
    let ok = unsafe { zipherx_ffi::zipherx_tree_root(std::ptr::null_mut()) };
    assert!(!ok, "Null tree_root must return false");
}

#[test]
#[serial]
fn null_tree_append() {
    let pos = unsafe { zipherx_ffi::zipherx_tree_append(std::ptr::null()) };
    assert_eq!(pos, u64::MAX, "Null tree_append must return u64::MAX");
}

#[test]
#[serial]
fn null_tree_append_batch() {
    let pos = unsafe { zipherx_ffi::zipherx_tree_append_batch(std::ptr::null(), 5) };
    assert_eq!(pos, u64::MAX, "Null tree_append_batch must return u64::MAX");
}

#[test]
#[serial]
fn null_tree_serialize() {
    let ok = unsafe {
        zipherx_ffi::zipherx_tree_serialize(std::ptr::null_mut(), std::ptr::null_mut())
    };
    assert!(!ok, "Null tree_serialize must return false");
}

// ═══════════════════════════════════════════════════════════
// Null Pointer: Crypto
// ═══════════════════════════════════════════════════════════

#[test]
fn null_double_sha256() {
    let ok = unsafe {
        zipherx_ffi::zipherx_double_sha256(std::ptr::null(), 0, std::ptr::null_mut())
    };
    assert!(!ok, "Null double_sha256 must return false");
}

#[test]
fn null_verify_equihash() {
    let ok = unsafe {
        zipherx_ffi::zipherx_verify_equihash(std::ptr::null(), std::ptr::null(), 400)
    };
    assert!(!ok, "Null verify_equihash must return false");
}

#[test]
fn null_random_scalar() {
    let ok = unsafe { zipherx_ffi::zipherx_random_scalar(std::ptr::null_mut()) };
    assert!(!ok, "Null random_scalar must return false");
}

// ═══════════════════════════════════════════════════════════
// Null Pointer: Memory Management
// ═══════════════════════════════════════════════════════════

#[test]
fn null_free_no_crash() {
    // Must not crash
    unsafe { zipherx_ffi::zipherx_free(std::ptr::null_mut(), 0) };
}

#[test]
fn null_free_buffer_no_crash() {
    // Must not crash
    unsafe { zipherx_ffi::zipherx_free_buffer(std::ptr::null_mut()) };
}

// ═══════════════════════════════════════════════════════════
// Invalid Data
// ═══════════════════════════════════════════════════════════

#[test]
#[serial]
fn tree_deserialize_too_short() {
    let data = [0u8; 4]; // Less than 8 bytes (minimum for position)
    let ok = unsafe { zipherx_ffi::zipherx_tree_deserialize(data.as_ptr(), data.len()) };
    assert!(!ok, "Deserialize with 4 bytes must fail");
}

#[test]
#[serial]
fn tree_deserialize_corrupted() {
    // 100 bytes of garbage with absurd position value
    let mut data = vec![0xFFu8; 100];
    data[0..8].copy_from_slice(&u64::MAX.to_le_bytes());
    let ok = unsafe { zipherx_ffi::zipherx_tree_deserialize(data.as_ptr(), data.len()) };
    assert!(!ok, "Deserialize corrupted data must fail");
}

#[test]
#[serial]
fn tree_load_from_cmus_too_short() {
    let data = [0u8; 4]; // Less than 8 bytes
    let ok = unsafe { zipherx_ffi::zipherx_tree_load_from_cmus(data.as_ptr(), data.len()) };
    assert!(!ok, "load_from_cmus with 4 bytes must fail");
}

// ═══════════════════════════════════════════════════════════
// Witness: Null / Invalid
// ═══════════════════════════════════════════════════════════

#[test]
#[serial]
fn null_tree_get_witness() {
    let ok = unsafe { zipherx_ffi::zipherx_tree_get_witness(0, std::ptr::null_mut()) };
    assert!(!ok, "Null tree_get_witness must return false");
}

#[test]
fn null_witness_get_root() {
    let ok = unsafe {
        zipherx_ffi::zipherx_witness_get_root(
            std::ptr::null(),
            0,
            std::ptr::null_mut(),
        )
    };
    assert!(!ok, "Null witness_get_root must return false");
}

#[test]
fn witness_path_is_valid_null() {
    let ok = unsafe { zipherx_ffi::zipherx_witness_path_is_valid(std::ptr::null(), 0) };
    assert!(!ok, "Null witness_path_is_valid must return false");
}
