/// Verify nullifier computation against known chain data
/// This tests that our nullifier computation matches what's on the blockchain

use std::fs;
use zcash_primitives::sapling::{Diversifier, Rseed, note_encryption::sapling_note_encryption};
use zcash_primitives::zip32::ExtendedSpendingKey;
use bech32::{self, FromBase32, Variant};
use jubjub::Fr;
use ff::PrimeField;

fn main() {
    println!("=== Nullifier Verification Test ===\n");

    // User's spending key (Bech32 format)
    let spending_key_bech32 = "***REDACTED-SPENDING-KEY***";

    // Decode the spending key
    let (hrp, data, _variant) = bech32::decode(spending_key_bech32).expect("Invalid Bech32");
    assert_eq!(hrp, "secret-extended-key-main", "Wrong HRP");
    let sk_bytes = Vec::<u8>::from_base32(&data).expect("Invalid base32");
    println!("Spending key bytes: {} bytes", sk_bytes.len());

    let extsk = ExtendedSpendingKey::read(&sk_bytes[..]).expect("Failed to parse spending key");
    let dfvk = extsk.to_diversifiable_full_viewing_key();
    let nk = dfvk.fvk().vk.nk;

    // Get the payment address from the key
    let (_, payment_address) = extsk.default_address();
    println!("Payment address diversifier: {:?}", payment_address.diversifier().0);

    // CMUs from tx 1fbd1e9d8f91e1c17eb92c5acbfcca7c9ecfcde13dd8e22c42d3d315700f8db5
    // These are in DISPLAY format (big-endian)
    let cmu0_display = "454aecc8b18a991554a816a0c40a7f160aca41b53a4cffd32afbdb443404730a";
    let cmu1_display = "0ee10cb057ba2c9102fff07eb33f733f574e98a28830b6e9fde4c8d0c5d70f94";

    // Convert to wire format (little-endian) by reversing bytes
    let cmu0_wire = reverse_hex(cmu0_display);
    let cmu1_wire = reverse_hex(cmu1_display);

    println!("\nCMU 0 (display): {}", cmu0_display);
    println!("CMU 0 (wire):    {}", cmu0_wire);
    println!("\nCMU 1 (display): {}", cmu1_display);
    println!("CMU 1 (wire):    {}", cmu1_wire);

    // Load bundled CMU data to find position
    let cmu_data = fs::read("/Users/chris/ZipherX/Resources/commitment_tree.bin")
        .expect("Failed to read commitment tree");
    println!("\nBundled tree: {} bytes", cmu_data.len());

    // Read CMU count
    let count = u64::from_le_bytes(cmu_data[0..8].try_into().unwrap());
    println!("Total CMUs in bundled tree: {}", count);

    // Search for CMU 0 (wire format)
    let cmu0_bytes = hex::decode(&cmu0_wire).expect("Invalid hex");
    let pos0 = find_cmu_position(&cmu_data, &cmu0_bytes);
    println!("\nPosition of CMU 0 in tree: {:?}", pos0);

    // Search for CMU 1 (wire format)
    let cmu1_bytes = hex::decode(&cmu1_wire).expect("Invalid hex");
    let pos1 = find_cmu_position(&cmu_data, &cmu1_bytes);
    println!("Position of CMU 1 in tree: {:?}", pos1);

    // Expected nullifier from chain (display format, big-endian)
    // This is from tx 63038d91... vShieldedSpend
    let expected_nf_display = "c74900d8932caf653e2063f1b3338ab73101e73d18492c17ada8c930c5c625cd";
    let expected_nf_wire = reverse_hex(expected_nf_display);
    println!("\n=== Expected Nullifier ===");
    println!("Display format: {}", expected_nf_display);
    println!("Wire format:    {}", expected_nf_wire);

    // Now I need to get the note parameters (diversifier, value, rcm) to compute nullifier
    // These come from decrypting the note output
    // For now, I'll test with known values if available

    // The note was 0.01 ZCL = 1,000,000 zatoshis
    let note_value: u64 = 1_000_000;

    println!("\n=== Note Parameters ===");
    println!("Value: {} zatoshis", note_value);

    // To complete the test, we need to decrypt the note to get diversifier and rcm
    // This requires the full encCiphertext

    // For now, let's verify at least that the CMU position lookup works
    if pos0.is_some() || pos1.is_some() {
        println!("\n✅ CMU position lookup is working!");
    } else {
        println!("\n❌ CMU NOT FOUND in bundled tree!");
        println!("   This means the note was received AFTER the bundled tree cutoff,");
        println!("   or there's a byte order mismatch in the CMU lookup.");
    }
}

fn find_cmu_position(cmu_data: &[u8], target: &[u8]) -> Option<u64> {
    if cmu_data.len() < 8 || target.len() != 32 {
        return None;
    }

    let count = u64::from_le_bytes(cmu_data[0..8].try_into().unwrap());
    let mut offset = 8;

    for i in 0..count {
        if offset + 32 > cmu_data.len() {
            break;
        }
        if &cmu_data[offset..offset + 32] == target {
            return Some(i);
        }
        offset += 32;
    }

    None
}

fn reverse_hex(hex_str: &str) -> String {
    let bytes = hex::decode(hex_str).expect("Invalid hex");
    let reversed: Vec<u8> = bytes.iter().rev().cloned().collect();
    hex::encode(reversed)
}
