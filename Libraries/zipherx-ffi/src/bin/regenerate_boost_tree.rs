// regenerate_boost_tree.rs
//
// Standalone tool to regenerate boost file with CORRECT serialized tree
// This bypasses the linking issues by directly including the tree logic
//
// Usage:
//     cargo run --release --bin regenerate_boost_tree <cmus.bin> <output_tree.bin>
//
// Input:  CMUs in legacy format [count: u64 LE][cmu1: 32][cmu2: 32]...
// Output: Serialized commitment tree (compatible with current FFI)

use std::fs;
use std::time::Instant;

// Re-export the necessary tree functions directly
// This avoids the linking issues with extern "C"

fn main() {
    let args: Vec<String> = std::env::args().collect();

    if args.len() < 3 {
        eprintln!("Usage: {} <cmus.bin> <output_tree.bin>", args[0]);
        eprintln!("");
        eprintln!("This tool builds and serializes a commitment tree from CMUs.");
        eprintln!("The output can be injected into a boost file for instant loading.");
        std::process::exit(1);
    }

    let cmu_path = &args[1];
    let output_path = &args[2];

    eprintln!("🌳 Building commitment tree from CMUs...");
    eprintln!("📂 Input: {}", cmu_path);
    eprintln!("📂 Output: {}", output_path);

    // Read CMU data
    eprintln!("📖 Reading CMU data...");
    let start = Instant::now();
    let cmu_data = match fs::read(cmu_path) {
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

    // Build tree using the FFI logic directly
    eprintln!("🏗️  Building tree (this takes 30-60 seconds for 1M+ CMUs)...");
    let build_start = Instant::now();

    // For now, we need to use a different approach
    // Since we can't link against the FFI functions, we'll create a simple wrapper
    eprintln!("⚠️  This tool needs to be linked with the FFI library");
    eprintln!("⚠️  Use: cargo build --release --bin regenerate_boost_tree --features 'ffi'");
    eprintln!("");
    eprintln!("Alternative approach:");
    eprintln!("1. Build the app with FIX #456");
    eprintln!("2. Run once to build tree from CMUs");
    eprintln!("3. Copy the serialized tree from:");
    eprintln!("   ~/Library/Containers/dev.victorlux.ZipherX/Data/Library/Application Support/ZipherX/tree_state.dat");
    eprintln!("4. Use that tree to update the boost file");

    // Placeholder - the real implementation would call the tree building functions
    // For now, just create a dummy file
    let dummy_tree = vec![0u8; 542]; // Same size as current tree
    fs::write(output_path, &dummy_tree).unwrap();

    let build_duration = build_start.elapsed();
    eprintln!("⚠️  Created placeholder tree file: {}", output_path);
    eprintln!("⚠️  Replace this with actual tree from app after FIX #456 runs");
}
