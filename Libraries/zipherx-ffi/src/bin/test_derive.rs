use zcash_primitives::{
    sapling::{
        keys::FullViewingKey,
        PaymentAddress,
    },
    zip32::{ChildIndex, sapling::ExtendedSpendingKey},
};
use ff::PrimeField;
use group::GroupEncoding;
use bech32::ToBase32;

fn main() {
    // Use a test seed
    let seed = [0u8; 64];
    
    // Derive key the same way as our FFI
    let master = ExtendedSpendingKey::master(&seed);
    let account_key = master
        .derive_child(ChildIndex::Hardened(32))
        .derive_child(ChildIndex::Hardened(147))
        .derive_child(ChildIndex::Hardened(0));
    
    let expsk = &account_key.expsk;
    
    println!("ask: {:?}", expsk.ask.to_repr());
    println!("nsk: {:?}", expsk.nsk.to_repr());
    println!("ovk: {:?}", expsk.ovk.0);
    
    // Derive FVK
    let fvk = FullViewingKey::from_expanded_spending_key(expsk);
    
    println!("\nak (compressed): {:?}", fvk.vk.ak.to_bytes());
    
    // Get default address from ExtendedSpendingKey
    let (div_idx, default_addr) = account_key.default_address();
    println!("\nDefault address diversifier index: {:?}", div_idx);
    println!("Default address bytes: {:?}", default_addr.to_bytes());
    
    // Encode as bech32
    let encoded = bech32::encode("zs", default_addr.to_bytes().to_base32(), bech32::Variant::Bech32).unwrap();
    println!("\nEncoded address: {}", encoded);
    println!("Address length: {}", encoded.len());
    
    // Verify it parses back
    if PaymentAddress::from_bytes(&default_addr.to_bytes()).is_some() {
        println!("✅ Address is valid!");
    } else {
        println!("❌ Address is invalid!");
    }
}
