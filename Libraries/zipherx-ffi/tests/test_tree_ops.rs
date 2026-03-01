//! Merkle tree operation tests (init, append, root, serialize, deserialize)
//!
//! All tests use #[serial] — tree operations modify global Mutex state.

mod common;
use common::*;
use serial_test::serial;

// ═══════════════════════════════════════════════════════════
// Tree Init
// ═══════════════════════════════════════════════════════════

#[test]
#[serial]
fn tree_init_resets_size() {
    assert!(tree_init(), "tree_init must succeed");
    assert_eq!(tree_size(), 0, "Tree size must be 0 after init");
}

#[test]
#[serial]
fn tree_init_clears_previous() {
    tree_init();
    let cmu = hex_to_array::<32>(FIRST_CMU_WIRE_HEX);
    tree_append(&cmu).unwrap();
    assert_eq!(tree_size(), 1);

    // Re-init should clear
    tree_init();
    assert_eq!(tree_size(), 0, "Tree must be empty after re-init");
}

// ═══════════════════════════════════════════════════════════
// Tree Append
// ═══════════════════════════════════════════════════════════

#[test]
#[serial]
fn tree_append_single_cmu() {
    tree_init();
    let cmu = hex_to_array::<32>(FIRST_CMU_WIRE_HEX);
    let pos = tree_append(&cmu).expect("append failed");
    assert_eq!(pos, 0, "First CMU should be at position 0");
    assert_eq!(tree_size(), 1, "Tree size should be 1 after append");
}

#[test]
#[serial]
fn tree_append_sequential_positions() {
    tree_init();
    let cmu = hex_to_array::<32>(FIRST_CMU_WIRE_HEX);

    for i in 0u64..5 {
        let pos = tree_append(&cmu).expect("append failed");
        assert_eq!(pos, i, "Position must be sequential: expected {}, got {}", i, pos);
    }
    assert_eq!(tree_size(), 5);
}

#[test]
#[serial]
fn tree_size_increments_with_appends() {
    tree_init();
    let cmu = hex_to_array::<32>(FIRST_CMU_WIRE_HEX);

    for expected_size in 1u64..=5 {
        tree_append(&cmu).unwrap();
        assert_eq!(tree_size(), expected_size);
    }
}

// ═══════════════════════════════════════════════════════════
// Tree Root
// ═══════════════════════════════════════════════════════════

#[test]
#[serial]
fn tree_empty_root_is_nonzero() {
    tree_init();
    let root = tree_root().expect("root failed on empty tree");
    assert_ne!(root, [0u8; 32], "Empty tree root must not be all zeros");
}

#[test]
#[serial]
fn tree_root_after_first_cmu_matches_expected() {
    tree_init();
    let cmu = hex_to_array::<32>(FIRST_CMU_WIRE_HEX);
    tree_append(&cmu).unwrap();

    let root = tree_root().expect("root failed");
    let expected = hex_to_array::<32>(FIRST_CMU_ROOT_WIRE_HEX);

    assert_eq!(
        hex_encode(&root),
        hex_encode(&expected),
        "Root must match known vector from test_first_cmu.rs"
    );
}

#[test]
#[serial]
fn tree_root_changes_per_append() {
    tree_init();
    let cmu = hex_to_array::<32>(FIRST_CMU_WIRE_HEX);

    let root0 = tree_root().unwrap();
    tree_append(&cmu).unwrap();
    let root1 = tree_root().unwrap();
    tree_append(&cmu).unwrap();
    let root2 = tree_root().unwrap();

    assert_ne!(root0, root1, "Root must change after first append");
    assert_ne!(root1, root2, "Root must change after second append");
}

// ═══════════════════════════════════════════════════════════
// Batch Append
// ═══════════════════════════════════════════════════════════

#[test]
#[serial]
fn tree_append_batch_multiple() {
    tree_init();
    let cmu = hex_to_array::<32>(FIRST_CMU_WIRE_HEX);
    let cmus = vec![cmu; 5];
    let start_pos = tree_append_batch(&cmus).expect("batch append failed");
    assert_eq!(start_pos, 0, "Start position should be 0 for first batch");
    assert_eq!(tree_size(), 5, "Tree should have 5 CMUs after batch");
}

// ═══════════════════════════════════════════════════════════
// Serialize / Deserialize
// ═══════════════════════════════════════════════════════════

#[test]
#[serial]
fn tree_serialize_deserialize_roundtrip() {
    tree_init();
    let cmu = hex_to_array::<32>(FIRST_CMU_WIRE_HEX);
    tree_append(&cmu).unwrap();
    tree_append(&cmu).unwrap();
    tree_append(&cmu).unwrap();

    let root_before = tree_root().unwrap();
    let serialized = tree_serialize().expect("serialize failed");
    assert!(serialized.len() > 8, "Serialized tree must be > 8 bytes");

    // Re-init and deserialize
    tree_init();
    assert!(tree_deserialize(&serialized), "deserialize must succeed");

    let root_after = tree_root().unwrap();
    assert_eq!(
        root_before, root_after,
        "Root must match after serialize/deserialize round-trip"
    );
}

// ═══════════════════════════════════════════════════════════
// Load from CMUs (bundled format)
// ═══════════════════════════════════════════════════════════

#[test]
#[serial]
fn tree_load_from_cmus_bundled_format() {
    tree_init();
    let cmu = hex_to_array::<32>(FIRST_CMU_WIRE_HEX);

    // Build bundled format: [count: u64 LE][cmu1: 32 bytes]
    let count: u64 = 1;
    let mut data = Vec::new();
    data.extend_from_slice(&count.to_le_bytes());
    data.extend_from_slice(&cmu);

    assert!(tree_load_from_cmus(&data), "load_from_cmus must succeed");
    assert_eq!(tree_size(), 1, "Tree must have 1 CMU");

    // Root should match the expected root from test_first_cmu.rs
    let root = tree_root().unwrap();
    let expected = hex_to_array::<32>(FIRST_CMU_ROOT_WIRE_HEX);
    assert_eq!(
        hex_encode(&root),
        hex_encode(&expected),
        "Root from load_from_cmus must match known vector"
    );
}

// ═══════════════════════════════════════════════════════════
// Delta CMUs
// ═══════════════════════════════════════════════════════════

#[test]
#[serial]
fn delta_cmus_count_starts_at_zero() {
    tree_init();
    // After init, delta count depends on implementation — it may be cleared
    let count = get_delta_cmus_count();
    assert_eq!(count, 0, "Delta CMU count should be 0 after tree_init");
}
