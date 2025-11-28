/// Export a pre-serialized commitment tree for bundling in the iOS app
///
/// Usage: cargo run --bin export_serialized_tree <input_cmus.bin> <output_serialized.bin>
///
/// This tool:
/// 1. Loads CMUs from the bundled binary file (commitment_tree_v4.bin)
/// 2. Builds the commitment tree
/// 3. Serializes the tree to a format that can be instantly deserialized on app launch
///
/// The serialized tree can be loaded in ~1 second vs ~53 seconds for building from CMUs.

use std::env;
use std::fs::File;
use std::io::{Read, Write};
use incrementalmerkletree::frontier::CommitmentTree;
use zcash_primitives::sapling;
use zcash_primitives::merkle_tree::HashSer;

const DEPTH: u8 = 32;

fn main() {
    let args: Vec<String> = env::args().collect();

    if args.len() != 3 {
        eprintln!("Usage: {} <input_cmus.bin> <output_serialized.bin>", args[0]);
        eprintln!("\nExample:");
        eprintln!("  cargo run --bin export_serialized_tree \\");
        eprintln!("    /Users/chris/ZipherX/Resources/commitment_tree_v4.bin \\");
        eprintln!("    /Users/chris/ZipherX/Resources/commitment_tree_serialized.bin");
        std::process::exit(1);
    }

    let input_path = &args[1];
    let output_path = &args[2];

    println!("📂 Loading CMUs from: {}", input_path);

    // Read input file
    let mut file = File::open(input_path).expect("Failed to open input file");
    let mut data = Vec::new();
    file.read_to_end(&mut data).expect("Failed to read input file");

    // Parse header: count (8 bytes)
    if data.len() < 8 {
        eprintln!("❌ Input file too small");
        std::process::exit(1);
    }

    let count = u64::from_le_bytes(data[0..8].try_into().unwrap());
    println!("📊 CMU count: {}", count);

    let expected_size = 8 + (count as usize * 32);
    if data.len() < expected_size {
        eprintln!("❌ File too small: expected {} bytes, got {}", expected_size, data.len());
        std::process::exit(1);
    }

    // Build commitment tree
    println!("🌳 Building commitment tree...");
    let mut tree: CommitmentTree<sapling::Node, DEPTH> = CommitmentTree::empty();
    let mut position: u64 = 0;

    let start_time = std::time::Instant::now();
    let mut last_report = 0u64;

    for i in 0..count {
        let offset = 8 + (i as usize * 32);
        let cmu_bytes: [u8; 32] = data[offset..offset+32].try_into().unwrap();

        // Parse as Node (little-endian wire format)
        let node = match sapling::Node::read(&cmu_bytes[..]) {
            Ok(n) => n,
            Err(e) => {
                eprintln!("❌ Failed to parse CMU {}: {}", i, e);
                std::process::exit(1);
            }
        };

        // Append to tree
        if tree.append(node).is_err() {
            eprintln!("❌ Failed to append CMU {}", i);
            std::process::exit(1);
        }
        position = i + 1;

        // Progress report every 100k CMUs
        if position - last_report >= 100_000 {
            let elapsed = start_time.elapsed().as_secs_f64();
            let rate = position as f64 / elapsed;
            println!("  {} / {} CMUs ({:.1}%), {:.0} CMUs/sec",
                     position, count,
                     (position as f64 / count as f64) * 100.0,
                     rate);
            last_report = position;
        }
    }

    let build_time = start_time.elapsed();
    println!("✅ Tree built in {:.1} seconds", build_time.as_secs_f64());
    println!("📊 Tree size: {} nodes", position);

    // Get tree root for verification
    let root = tree.root();
    let mut root_bytes = Vec::new();
    root.write(&mut root_bytes).expect("Failed to write root");
    let root_hex: String = root_bytes.iter().rev().map(|b| format!("{:02x}", b)).collect();
    println!("🌲 Tree root (display): {}", root_hex);

    // Serialize tree
    println!("💾 Serializing tree...");
    let mut output_data = Vec::new();

    // Write position first (8 bytes, little-endian)
    output_data.extend_from_slice(&position.to_le_bytes());

    // Serialize tree using zcash_primitives write function
    zcash_primitives::merkle_tree::write_commitment_tree(&tree, &mut output_data)
        .expect("Failed to serialize tree");

    println!("📊 Serialized size: {} bytes ({:.1} MB)",
             output_data.len(),
             output_data.len() as f64 / 1_000_000.0);

    // Write output file
    let mut out_file = File::create(output_path).expect("Failed to create output file");
    out_file.write_all(&output_data).expect("Failed to write output file");

    println!("✅ Serialized tree saved to: {}", output_path);
    println!("\n📋 Summary:");
    println!("   Input:  {} CMUs ({:.1} MB)", count, (count * 32 + 8) as f64 / 1_000_000.0);
    println!("   Output: {} bytes ({:.1} MB)", output_data.len(), output_data.len() as f64 / 1_000_000.0);
    println!("   Build time: {:.1} seconds", build_time.as_secs_f64());
    println!("   Tree root: {}", root_hex);
    println!("\n🚀 On-device load time: ~1 second (vs ~53 seconds from CMUs)");
}
