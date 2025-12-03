// test_deserialize.rs - Test that commitment_tree_serialized.bin can be deserialized correctly
//
// Usage: cargo run --release --bin test_deserialize <serialized_tree.bin>

use std::fs::File;
use std::io::Read;
use incrementalmerkletree::frontier::CommitmentTree;
use zcash_primitives::merkle_tree::{HashSer, read_commitment_tree};

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 2 {
        eprintln!("Usage: test_deserialize <serialized_tree.bin>");
        return;
    }

    let input_path = &args[1];

    // Read serialized tree file
    println!("📂 Reading serialized tree: {}", input_path);
    let mut file = File::open(input_path).expect("Failed to open input file");
    let mut data = Vec::new();
    file.read_to_end(&mut data).expect("Failed to read file");
    println!("📊 File size: {} bytes", data.len());

    if data.len() < 8 {
        eprintln!("❌ File too small (< 8 bytes)");
        return;
    }

    // Read position (first 8 bytes)
    let position = u64::from_le_bytes(data[0..8].try_into().unwrap());
    println!("📍 Position (tree size): {}", position);

    // Deserialize tree
    println!("🌳 Deserializing tree...");
    let start = std::time::Instant::now();

    let tree: CommitmentTree<zcash_primitives::sapling::Node, 32> = match read_commitment_tree(&data[8..]) {
        Ok(t) => t,
        Err(e) => {
            eprintln!("❌ Failed to deserialize tree: {:?}", e);
            return;
        }
    };

    let elapsed = start.elapsed();
    println!("✅ Tree deserialized in {:.3}s", elapsed.as_secs_f64());

    // Get root
    let root = tree.root();
    let mut root_bytes = [0u8; 32];
    root.write(&mut root_bytes[..]).expect("Failed to write root");
    let root_display: Vec<u8> = root_bytes.iter().rev().copied().collect();
    println!("🔑 Tree root: {}", hex::encode(&root_display));

    // Expected root at height 2926122
    let expected = "5cc45e5ed5008b68e0098fdc7ea52cc25caa4400b3bc62c6701bbfc581990945";
    if hex::encode(&root_display) == expected {
        println!("✅ Root matches expected value!");
    } else {
        println!("❌ Root mismatch!");
        println!("   Expected: {}", expected);
    }
}
