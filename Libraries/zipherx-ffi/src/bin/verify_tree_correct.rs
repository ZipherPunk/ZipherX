use std::fs::File;
use std::io::Read;
use incrementalmerkletree::frontier::CommitmentTree;
use zcash_primitives::merkle_tree::HashSer;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 2 {
        eprintln!("Usage: verify_tree_correct <path>");
        return;
    }
    
    let path = &args[1];
    let mut file = File::open(path).expect("Failed to open file");
    let mut data = Vec::new();
    file.read_to_end(&mut data).expect("Failed to read file");
    
    // Read count
    let count = u64::from_le_bytes(data[0..8].try_into().unwrap());
    println!("CMU count: {}", count);
    
    // Build tree - pass CMUs directly to Node::read (they're in wire format)
    let mut tree: CommitmentTree<zcash_primitives::sapling::Node, 32> = CommitmentTree::empty();
    
    let mut offset = 8;
    for i in 0..count {
        let cmu_bytes: [u8; 32] = data[offset..offset + 32].try_into().unwrap();
        offset += 32;
        
        // Parse directly WITHOUT reversing - bundled file is in wire format
        let node = match zcash_primitives::sapling::Node::read(&cmu_bytes[..]) {
            Ok(n) => n,
            Err(e) => {
                eprintln!("Failed to parse CMU {}: {:?}", i, e);
                return;
            }
        };
        
        if tree.append(node).is_err() {
            eprintln!("Failed to append CMU {}", i);
            return;
        }
        
        if i > 0 && i % 200000 == 0 {
            println!("Progress: {}/{}", i, count);
        }
    }
    
    // Get root and convert to display format (reversed)
    let root = tree.root();
    let mut root_bytes = [0u8; 32];
    root.write(&mut root_bytes[..]).expect("Failed to write root");
    
    // Root from Node::write is in wire format (little-endian)
    // zcashd displays it in big-endian, so reverse for display
    let root_display: Vec<u8> = root_bytes.iter().rev().copied().collect();
    
    println!("\nTree root (wire format):    {}", hex::encode(root_bytes));
    println!("Tree root (display format): {}", hex::encode(&root_display));
    println!("\nExpected zcashd finalsaplingroot at height 2922769:");
    println!("28725db1847d9c6aaab88184b52ef99f60975adfdd90321a57ace5f99304912b");
}
