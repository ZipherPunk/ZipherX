// serialize_tree.rs - Generate pre-serialized commitment tree for instant loading
//
// This tool takes the CMU file (commitment_tree.bin) and generates a
// serialized tree file that can be loaded instantly via treeDeserialize()
// instead of rebuilding from 1M+ CMUs (which takes ~56 seconds).
//
// Usage: cargo run --release --bin serialize_tree <input.bin> <output.bin>

use std::fs::File;
use std::io::{Read, Write as IoWrite};
use incrementalmerkletree::frontier::CommitmentTree;
use zcash_primitives::merkle_tree::{HashSer, write_commitment_tree};

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 3 {
        eprintln!("Usage: serialize_tree <input_cmus.bin> <output_tree.bin>");
        eprintln!("\nThis tool creates a pre-serialized commitment tree from CMUs.");
        eprintln!("The output file can be loaded instantly instead of rebuilding.");
        return;
    }

    let input_path = &args[1];
    let output_path = &args[2];

    // Read CMU file
    println!("📂 Reading CMU file: {}", input_path);
    let mut file = File::open(input_path).expect("Failed to open input file");
    let mut data = Vec::new();
    file.read_to_end(&mut data).expect("Failed to read file");

    // Read count (first 8 bytes)
    let count = u64::from_le_bytes(data[0..8].try_into().unwrap());
    println!("📊 CMU count: {}", count);

    // Build tree from CMUs
    println!("🌳 Building commitment tree...");
    let mut tree: CommitmentTree<zcash_primitives::sapling::Node, 32> = CommitmentTree::empty();

    let mut offset = 8;
    let start = std::time::Instant::now();

    for i in 0..count {
        let cmu_bytes: [u8; 32] = data[offset..offset + 32].try_into().unwrap();
        offset += 32;

        // Parse directly WITHOUT reversing - bundled file is in wire format
        let node = match zcash_primitives::sapling::Node::read(&cmu_bytes[..]) {
            Ok(n) => n,
            Err(e) => {
                eprintln!("❌ Failed to parse CMU {}: {:?}", i, e);
                return;
            }
        };

        if tree.append(node).is_err() {
            eprintln!("❌ Failed to append CMU {}", i);
            return;
        }

        if i > 0 && i % 200000 == 0 {
            let elapsed = start.elapsed().as_secs();
            let rate = i as f64 / elapsed.max(1) as f64;
            println!("  Progress: {}/{} ({:.0} CMUs/sec)", i, count, rate);
        }
    }

    let build_time = start.elapsed();
    println!("✅ Tree built in {:.1}s", build_time.as_secs_f64());

    // Verify root
    let root = tree.root();
    let mut root_bytes = [0u8; 32];
    root.write(&mut root_bytes[..]).expect("Failed to write root");
    let root_display: Vec<u8> = root_bytes.iter().rev().copied().collect();
    println!("🔑 Tree root: {}", hex::encode(&root_display));

    // Serialize tree
    println!("💾 Serializing tree...");
    let serialize_start = std::time::Instant::now();

    let mut serialized = Vec::new();

    // Write position first (tree size) - same format as zipherx_tree_serialize
    let position = count;
    serialized.extend_from_slice(&position.to_le_bytes());

    // Write tree data
    write_commitment_tree(&tree, &mut serialized).expect("Failed to serialize tree");

    let serialize_time = serialize_start.elapsed();
    println!("✅ Serialized in {:.3}s ({} bytes)", serialize_time.as_secs_f64(), serialized.len());

    // Write to output file
    let mut output_file = File::create(output_path).expect("Failed to create output file");
    output_file.write_all(&serialized).expect("Failed to write output");

    println!("\n📁 Output: {}", output_path);
    println!("📊 Size: {} bytes ({:.2} MB)", serialized.len(), serialized.len() as f64 / 1024.0 / 1024.0);
    println!("\n🚀 This file can be loaded instantly via treeDeserialize()");
    println!("   instead of rebuilding from CMUs ({:.1}s → <1s)", build_time.as_secs_f64());
}
