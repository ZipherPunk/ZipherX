use incrementalmerkletree::frontier::CommitmentTree;
use zcash_primitives::merkle_tree::HashSer;

fn main() {
    // First CMU from zcashd: 5a8d47a74b48efce5841a43ddaccdc75253a4ccda847d67ada8309dcf01d3943
    // This is how zcashd returns it (display format, big-endian)
    let cmu_from_zcashd = hex::decode("5a8d47a74b48efce5841a43ddaccdc75253a4ccda847d67ada8309dcf01d3943").unwrap();
    
    // Same CMU reversed (little-endian wire format)
    let cmu_reversed: Vec<u8> = cmu_from_zcashd.iter().rev().copied().collect();
    
    println!("CMU from zcashd (big-endian):    {}", hex::encode(&cmu_from_zcashd));
    println!("CMU reversed (little-endian):    {}", hex::encode(&cmu_reversed));
    
    // Try parsing as Node with big-endian (as returned by zcashd)
    match zcash_primitives::sapling::Node::read(&cmu_from_zcashd[..]) {
        Ok(node) => {
            println!("\n✅ Node::read succeeded with big-endian");
            let mut tree: CommitmentTree<zcash_primitives::sapling::Node, 32> = CommitmentTree::empty();
            tree.append(node).unwrap();
            
            let root = tree.root();
            let mut root_bytes = [0u8; 32];
            root.write(&mut root_bytes[..]).unwrap();
            println!("   Root with 1 CMU (big-endian): {}", hex::encode(root_bytes));
        }
        Err(e) => println!("\n❌ Node::read failed with big-endian: {:?}", e),
    }
    
    // Try parsing as Node with little-endian
    match zcash_primitives::sapling::Node::read(&cmu_reversed[..]) {
        Ok(node) => {
            println!("\n✅ Node::read succeeded with little-endian");
            let mut tree: CommitmentTree<zcash_primitives::sapling::Node, 32> = CommitmentTree::empty();
            tree.append(node).unwrap();
            
            let root = tree.root();
            let mut root_bytes = [0u8; 32];
            root.write(&mut root_bytes[..]).unwrap();
            println!("   Root with 1 CMU (little-endian): {}", hex::encode(root_bytes));
        }
        Err(e) => println!("\n❌ Node::read failed with little-endian: {:?}", e),
    }
}
