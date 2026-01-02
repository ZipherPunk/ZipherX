// test_load_from_cmus.rs - Test that treeLoadFromCMUs produces correct root
//
// Usage: cargo run --release --bin test_load_from_cmus <legacy_cmus_v2.bin>

use std::fs::File;
use std::io::Read;
use incrementalmerkletree::frontier::CommitmentTree;
use zcash_primitives::merkle_tree::HashSer;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 2 {
        eprintln!("Usage: test_load_from_cmus <legacy_cmus_v2.bin>");
        return;
    }

    let input_path = &args[1];

    // Read CMU file
    println!("📂 Reading CMU file: {}", input_path);
    let mut file = File::open(input_path).expect("Failed to open input file");
    let mut data = Vec::new();
    file.read_to_end(&mut data).expect("Failed to read file");

    // Read count (first 8 bytes, little-endian)
    if data.len() < 8 {
        eprintln!("❌ File too small (< 8 bytes)");
        return;
    }

    let count = u64::from_le_bytes(data[0..8].try_into().unwrap());
    println!("📊 CMU count: {}", count);

    let expected_len = 8 + (count as usize * 32);
    if data.len() < expected_len {
        eprintln!("❌ File too short: expected {} bytes, got {}", expected_len, data.len());
        return;
    }

    // Build tree from CMUs - exactly like treeLoadFromCMUs
    println!("🌳 Building tree from CMUs (same as treeLoadFromCMUs)...");
    let start = std::time::Instant::now();

    let mut tree: CommitmentTree<zcash_primitives::sapling::Node, 32> = CommitmentTree::empty();

    let mut offset = 8;
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

    // Get root
    let root = tree.root();
    let mut root_bytes = [0u8; 32];
    root.write(&mut root_bytes[..]).expect("Failed to write root");
    let root_display: Vec<u8> = root_bytes.iter().rev().copied().collect();
    let root_hex = hex::encode(&root_display);

    println!("🔑 Tree root: {}", root_hex);

    // Expected root from boost manifest
    let expected = "0187103f5387f58fc2fa6a2bffbe7c63ad01552ee5671ac41100d97f054a4fc2";
    println!("🎯 Expected:  {}", expected);

    if root_hex == expected {
        println!("✅ ROOT MATCHES! treeLoadFromCMUs logic is correct!");
    } else {
        println!("❌ ROOT MISMATCH! Something is wrong!");
    }
}
