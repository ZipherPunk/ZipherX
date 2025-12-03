use incrementalmerkletree::frontier::CommitmentTree;
use zcash_primitives::merkle_tree::HashSer;

fn main() {
    // First CMU in bundled file (little-endian/wire format):
    // 43391df0dc0983da7ad647a8cd4c3a2575dcccda3da44158ceef484ba7478d5a
    let first_cmu_wire = hex::decode("43391df0dc0983da7ad647a8cd4c3a2575dcccda3da44158ceef484ba7478d5a").unwrap();
    
    // Parse as Node directly (no reversal - it's already in wire format)
    let node = zcash_primitives::sapling::Node::read(&first_cmu_wire[..]).expect("Failed to parse");
    
    // Build tree with one CMU
    let mut tree: CommitmentTree<zcash_primitives::sapling::Node, 32> = CommitmentTree::empty();
    tree.append(node).unwrap();
    
    // Get root
    let root = tree.root();
    let mut root_bytes = [0u8; 32];
    root.write(&mut root_bytes[..]).unwrap();
    
    // Root in display format (reversed)
    let root_display: Vec<u8> = root_bytes.iter().rev().copied().collect();
    
    println!("Root (wire):    {}", hex::encode(root_bytes));
    println!("Root (display): {}", hex::encode(&root_display));
    println!("\nExpected zcashd finalsaplingroot at height 476977:");
    println!("4fa518c5b25bb460710ba5e42d83b549100193abb5a895a20717dfeaf96116d4");
    
    if hex::encode(&root_display) == "4fa518c5b25bb460710ba5e42d83b549100193abb5a895a20717dfeaf96116d4" {
        println!("\n✅ ROOT MATCHES!");
    } else {
        println!("\n❌ ROOT MISMATCH!");
    }
}
