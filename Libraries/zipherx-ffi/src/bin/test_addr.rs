use bech32::FromBase32;
use zcash_primitives::sapling::PaymentAddress;

fn main() {
    let addr = "zs1rvcpa07m7ezyww977ln9vx8pdvhqf7859rnq3h4q6j4d5yusegddpsgtcj5q097ychs9jjrf2p2";
    
    let (_, data, _) = bech32::decode(addr).unwrap();
    let bytes = Vec::<u8>::from_base32(&data).unwrap();
    let mut addr_bytes = [0u8; 43];
    addr_bytes.copy_from_slice(&bytes);
    
    if PaymentAddress::from_bytes(&addr_bytes).is_some() {
        println!("✅ Valid Sapling payment address!");
    } else {
        println!("❌ Invalid!");
    }
}
