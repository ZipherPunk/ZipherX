//! Test adding CMUs to bundled tree to verify tree root matches zcashd

use std::fs;
use zcash_primitives::sapling::Node;
use incrementalmerkletree::{frontier::CommitmentTree, Hashable};
use zcash_primitives::merkle_tree::{read_commitment_tree, HashSer};
use ff::PrimeField;

const SAPLING_COMMITMENT_TREE_DEPTH: u8 = 32;

fn main() {
    let bundled_path = std::env::args().nth(1).expect("Usage: test_add_cmus <bundled_tree.bin>");

    println!("Loading bundled tree from: {}", bundled_path);

    // Read bundled tree file (format: [count: u64 LE][cmu1: 32 bytes][cmu2: 32 bytes]...)
    let data = fs::read(&bundled_path).expect("Failed to read bundled tree file");

    // Extract CMU count
    let count = u64::from_le_bytes(data[0..8].try_into().unwrap());
    println!("Bundled tree has {} CMUs", count);

    // Build tree from bundled CMUs
    println!("Building tree from bundled CMUs...");
    let mut tree: CommitmentTree<Node, SAPLING_COMMITMENT_TREE_DEPTH> = CommitmentTree::empty();

    for i in 0..count as usize {
        let offset = 8 + i * 32;
        let cmu_bytes: [u8; 32] = data[offset..offset+32].try_into().unwrap();

        // CMUs in bundled file are in wire format (little-endian)
        // Node::read expects wire format
        let node = Node::read(&cmu_bytes[..]).expect("Failed to parse CMU");
        tree.append(node).expect("Tree full");

        if (i + 1) % 200000 == 0 {
            println!("  Progress: {}/{}", i + 1, count);
        }
    }

    // Get root at height 2923123 (bundled tree end)
    let root_at_bundled = tree.root();
    let mut root_bytes = [0u8; 32];
    root_at_bundled.write(&mut root_bytes[..]).unwrap();
    println!("\nTree root at height 2923123 (bundled end):");
    println!("  Computed: {}", hex::encode(&root_bytes));
    println!("  Expected: 42d6a11f937de8a27060ad683a632be73d08fae9ff421145f58e16a282c702f3");

    // Now add the 4 CMUs between 2923124 and 2923169
    // These are from zcashd RPC in BIG-ENDIAN (display format)
    // We need to REVERSE them to little-endian (wire format) for Node::read()
    let cmus_big_endian = [
        // Block 2923149
        "35392eaf225683c804408f4d26435ffe572161cc362299667aef9f5d5315536a",
        // Block 2923164
        "5da07b3683f2c98305feb7e912d0c9d3d323016694d5c174c4981043eed07873",
        // Block 2923166
        "22ef4679c12ca16f1367ce0744153cd5058f9c162b230b54fc1a40cefee24526",
        // Block 2923169
        "5bad591a7aaa02fae1d3e0f3e96d152e44dfe616869e495b80f163f71a524bcd",
    ];

    println!("\nAdding 4 CMUs from blocks 2923149, 2923164, 2923166, 2923169...");

    for (i, cmu_hex) in cmus_big_endian.iter().enumerate() {
        let cmu_big: Vec<u8> = hex::decode(cmu_hex).expect("Invalid hex");

        // Reverse from big-endian (display) to little-endian (wire format)
        let cmu_le: Vec<u8> = cmu_big.iter().rev().cloned().collect();

        println!("  CMU {} (big-endian/display): {}", i + 1, cmu_hex);
        println!("  CMU {} (little-endian/wire): {}", i + 1, hex::encode(&cmu_le));

        // Parse as Node using wire format
        let node = Node::read(&cmu_le[..]).expect("Failed to parse CMU");
        tree.append(node).expect("Tree full");
    }

    // Get root at height 2923169
    let root_at_note = tree.root();
    let mut root_bytes = [0u8; 32];
    root_at_note.write(&mut root_bytes[..]).unwrap();

    println!("\nTree root at height 2923169 (after adding 4 CMUs):");
    println!("  Computed: {}", hex::encode(&root_bytes));
    println!("  Expected: 544dc4813498cd51c4c40794247cc800dd8cbc70a1e534a03630eee7948f24de");

    if hex::encode(&root_bytes) == "544dc4813498cd51c4c40794247cc800dd8cbc70a1e534a03630eee7948f24de" {
        println!("\n✅ SUCCESS! Tree root matches zcashd finalsaplingroot at height 2923169");
    } else {
        println!("\n❌ MISMATCH! Tree root does not match expected value");
    }
}
