//! Witness operation tests (create, load, update, verify)
//!
//! All tests use #[serial] — witness operations modify global Mutex state.

mod common;
use common::*;
use serial_test::serial;

// ═══════════════════════════════════════════════════════════
// Witness Clear
// ═══════════════════════════════════════════════════════════

#[test]
#[serial]
fn witnesses_clear_on_empty() {
    tree_init();
    let count = witnesses_clear();
    assert_eq!(count, 0, "Clearing empty witnesses should return 0");
}

// ═══════════════════════════════════════════════════════════
// Witness Get / Serialize
// ═══════════════════════════════════════════════════════════

#[test]
#[serial]
fn tree_get_witness_invalid_index() {
    tree_init();
    // No witnesses exist — index 0 should fail
    let result = tree_get_witness(0);
    assert!(result.is_none(), "Invalid witness index must return None");
}

#[test]
#[serial]
fn tree_get_witness_invalid_large_index() {
    tree_init();
    let result = tree_get_witness(999999);
    assert!(result.is_none(), "Large witness index must return None");
}

// ═══════════════════════════════════════════════════════════
// Witness Root
// ═══════════════════════════════════════════════════════════

#[test]
#[serial]
fn witness_get_root_requires_valid_data() {
    // Short buffer — should fail
    let short_data = [0u8; 10];
    let result = witness_get_root(&short_data);
    assert!(result.is_none(), "Witness root from 10-byte buffer must fail");
}

// ═══════════════════════════════════════════════════════════
// Witness Path Validation
// ═══════════════════════════════════════════════════════════

#[test]
#[serial]
fn witness_path_is_valid_rejects_short() {
    let short_data = [0u8; 50];
    assert!(
        !witness_path_is_valid(&short_data),
        "Short buffer must be invalid witness path"
    );
}

// ═══════════════════════════════════════════════════════════
// Witness Load
// ═══════════════════════════════════════════════════════════

#[test]
#[serial]
fn tree_load_witness_rejects_garbage() {
    tree_init();
    let garbage = [0xFFu8; 1028];
    // Loading garbage witness data — should fail gracefully
    let result = tree_load_witness(&garbage);
    assert!(result.is_none(), "Loading garbage witness must fail");
}

// ═══════════════════════════════════════════════════════════
// Witness Current Count
// ═══════════════════════════════════════════════════════════

#[test]
#[serial]
fn witness_current_after_clear() {
    tree_init();
    witnesses_clear();
    let count = witness_current();
    assert_eq!(count, 0, "Witness count should be 0 after clear");
}
