//! Verify commitment tree by computing root from CMU file
//!
//! Usage: cargo run --bin verify_tree /path/to/commitment_tree.bin

use std::env;
use std::fs::File;
use std::io::{Read, BufReader};
use incrementalmerkletree::frontier::CommitmentTree;
use zcash_primitives::sapling::Node;
use zcash_primitives::merkle_tree::HashSer;

fn main() {
    let args: Vec<String> = env::args().collect();
    let path = if args.len() > 1 {
        &args[1]
    } else {
        "commitment_tree.bin"
    };

    println!("🌳 Tree Verification Tool");
    println!("========================\n");
    println!("📁 Loading: {}", path);

    let file = match File::open(path) {
        Ok(f) => f,
        Err(e) => {
            eprintln!("❌ Failed to open file: {}", e);
            return;
        }
    };

    let mut reader = BufReader::new(file);

    // Read count (8 bytes little-endian)
    let mut count_buf = [0u8; 8];
    if reader.read_exact(&mut count_buf).is_err() {
        eprintln!("❌ Failed to read count");
        return;
    }
    let count = u64::from_le_bytes(count_buf);
    println!("📦 CMU count: {}", count);

    // Initialize tree
    let mut tree: CommitmentTree<Node, 32> = CommitmentTree::empty();

    // Read and append all CMUs
    let mut cmu_buf = [0u8; 32];
    let mut processed = 0u64;

    println!("⏳ Building tree...");

    loop {
        match reader.read_exact(&mut cmu_buf) {
            Ok(_) => {
                // Parse CMU as Node
                let node = match Node::read(&cmu_buf[..]) {
                    Ok(n) => n,
                    Err(e) => {
                        eprintln!("❌ Failed to parse CMU at position {}: {:?}", processed, e);
                        return;
                    }
                };

                // Append to tree
                if tree.append(node).is_err() {
                    eprintln!("❌ Failed to append CMU at position {}", processed);
                    return;
                }

                processed += 1;

                if processed % 100000 == 0 {
                    let progress = (processed as f64 / count as f64) * 100.0;
                    eprint!("\r⏳ Progress: {:.1}% ({}/{})", progress, processed, count);
                }
            }
            Err(_) => break,
        }
    }

    eprintln!("\r✅ Loaded {} CMUs                    ", processed);

    if processed != count {
        eprintln!("⚠️  Warning: Expected {} CMUs but read {}", count, processed);
    }

    // Get tree root
    let root = tree.root();

    // Convert to bytes and reverse for display (RPC shows big-endian)
    let mut root_bytes = [0u8; 32];
    root.write(&mut root_bytes[..]).unwrap();
    root_bytes.reverse();

    let root_hex: String = root_bytes.iter().map(|b| format!("{:02x}", b)).collect();

    println!("\n📊 Tree Statistics:");
    println!("   Size: {} commitments", processed);
    println!("   Root: {}", root_hex);

    println!("\n💡 Compare with chain's finalsaplingroot:");
    println!("   zclassic-cli getblockheader $(zclassic-cli getblockhash HEIGHT) true | grep finalsaplingroot");
}
