use std::fs::File;
use std::io::Read;
use incrementalmerkletree::frontier::CommitmentTree;
use zcash_primitives::merkle_tree::HashSer;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 2 {
        eprintln!("Usage: verify_tree_no_reverse <path>");
        return;
    }
    
    let path = &args[1];
    let mut file = File::open(path).expect("Failed to open file");
    let mut data = Vec::new();
    file.read_to_end(&mut data).expect("Failed to read file");
    
    // Read count
    let count = u64::from_le_bytes(data[0..8].try_into().unwrap());
    println!("CMU count: {}", count);
    
    // Build tree WITHOUT reversing - assuming file has correct wire format
    let mut tree: CommitmentTree<zcash_primitives::sapling::Node, 32> = CommitmentTree::empty();
    
    let mut offset = 8;
    for i in 0..std::cmp::min(count, 10000) {  // Just first 10000 for speed
        let cmu_bytes: [u8; 32] = data[offset..offset + 32].try_into().unwrap();
        offset += 32;
        
        // Parse directly WITHOUT reversing
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
    }
    
    // Get root
    let root = tree.root();
    let mut root_bytes = [0u8; 32];
    root.write(&mut root_bytes[..]).expect("Failed to write root");
    
    println!("Tree root (no reverse): {}", hex::encode(root_bytes));
}
