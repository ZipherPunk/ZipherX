// build_tree_from_cmus.rs
//
// Build commitment tree from CMUs and serialize
//
// Usage:
//     cargo run --release --bin build_tree_from_cmus <cmus.bin> <output_tree.bin>
//
// Input: CMUs in legacy format [count: u64 LE][cmu1: 32][cmu2: 32]...
// Output: Serialized commitment tree

use std::fs;
use std::time::Instant;
use incrementalmerkletree::frontier::CommitmentTree;
use zcash_primitives::sapling::Node;
use zcash_primitives::merkle_tree::{HashSer, write_commitment_tree};

fn main() {
    let args: Vec<String> = std::env::args().collect();

    if args.len() < 3 {
        eprintln!("Usage: {} <cmus.bin> <output_tree.bin>", args[0]);
        eprintln!("");
        eprintln!("Build commitment tree from CMUs and serialize");
        eprintln!("");
        eprintln!("Input:  CMUs in legacy format [count: u64 LE][cmu1: 32][cmu2: 32]...");
        eprintln!("Output: Serialized commitment tree");
        std::process::exit(1);
    }

    let input_path = &args[1];
    let output_path = &args[2];

    eprintln!("🌳 Building commitment tree from CMUs...");
    eprintln!("📂 Input: {}", input_path);
    eprintln!("📂 Output: {}", output_path);

    // Read CMU data
    eprintln!("📖 Reading CMU data...");
    let start = Instant::now();
    let cmu_data = match fs::read(input_path) {
        Ok(data) => data,
        Err(e) => {
            eprintln!("❌ Failed to read CMU file: {}", e);
            std::process::exit(1);
        }
    };

    eprintln!("✅ Read {} bytes of CMU data", cmu_data.len());

    // Parse CMU count
    if cmu_data.len() < 8 {
        eprintln!("❌ CMU file too small (no count)");
        std::process::exit(1);
    }

    let cmu_count = u64::from_le_bytes([
        cmu_data[0], cmu_data[1], cmu_data[2], cmu_data[3],
        cmu_data[4], cmu_data[5], cmu_data[6], cmu_data[7]
    ]) as usize;
    let expected_size = 8 + cmu_count * 32;

    if cmu_data.len() != expected_size {
        eprintln!("⚠️ Warning: CMU file size mismatch (expected {}, got {})", expected_size, cmu_data.len());
    }

    eprintln!("📊 CMU count: {}", cmu_count);

    // Build tree from CMUs
    eprintln!("🏗️  Building tree (this takes 30-60 seconds for 1M+ CMUs)...");
    let build_start = Instant::now();

    let mut tree: CommitmentTree<Node, 32> = CommitmentTree::empty();

    // Process CMUs in batches
    let batch_size = 10000;
    for batch_start in (0..cmu_count).step_by(batch_size) {
        let batch_end = std::cmp::min(batch_start + batch_size, cmu_count);

        for i in batch_start..batch_end {
            let offset = 8 + i * 32;
            let cmu_bytes = &cmu_data[offset..offset + 32];

            // FIX #557 v49: Reverse CMU from DISPLAY (big-endian) to WIRE (little-endian) format
            // before creating Node
            let mut reversed = [0u8; 32];
            let mut src_idx = 31;
            for dst_idx in 0..32 {
                reversed[dst_idx] = cmu_bytes[src_idx];
                src_idx -= 1;
            }

            let node = match Node::read(&reversed[..]) {
                Ok(n) => n,
                Err(e) => {
                    eprintln!("❌ Failed to parse CMU at offset {}: {:?}", offset, e);
                    std::process::exit(1);
                }
            };

            if tree.append(node).is_err() {
                eprintln!("❌ Failed to append CMU at position {}", i);
                std::process::exit(1);
            }
        }

        // Progress update
        let percent = (batch_end as f64 / cmu_count as f64) * 100.0;
        eprintln!("📊 Progress: {}/{} CMUs ({:.1}%)", batch_end, cmu_count, percent);
    }

    let build_duration = build_start.elapsed();
    eprintln!("✅ Tree built in {:?}", build_duration);

    // Get tree size (we track this manually via cmu_count)
    let tree_size = cmu_count as u64;
    eprintln!("📏 Tree size: {} commitments", tree_size);

    // Serialize tree
    eprintln!("💾 Serializing tree...");

    let mut data = Vec::new();

    // Write position (8 bytes little-endian)
    data.extend_from_slice(&tree_size.to_le_bytes());

    // Serialize tree using zcash_primitives function
    if write_commitment_tree(&tree, &mut data).is_err() {
        eprintln!("❌ Failed to serialize tree");
        std::process::exit(1);
    }

    eprintln!("✅ Serialized tree size: {} bytes", data.len());

    // Write to file
    if let Err(e) = fs::write(output_path, &data) {
        eprintln!("❌ Failed to write tree file: {}", e);
        std::process::exit(1);
    }

    let total_duration = start.elapsed();
    eprintln!("✅ Tree serialized and saved to: {}", output_path);
    eprintln!("⏱️  Total time: {:?}", total_duration);
}
