/// Find the exact position of a CMU in the commitment tree
/// and verify nullifier computation

use std::fs;
use zcash_primitives::sapling::{Diversifier, Rseed, PaymentAddress};
use zcash_primitives::zip32::ExtendedSpendingKey;
use bech32::{self, FromBase32};
use jubjub::Fr;
use ff::PrimeField;

const SPENDING_KEY_BECH32: &str = "***REDACTED-SPENDING-KEY***";

// CMU for the first received note (from tx 1fbd1e9d...) - display format (big-endian)
const CMU_DISPLAY: &str = "454aecc8b18a991554a816a0c40a7f160aca41b53a4cffd32afbdb443404730a";

// Expected nullifier from on-chain spending tx (display format)
const EXPECTED_NF_DISPLAY: &str = "c74900d8932caf653e2063f1b3338ab73101e73d18492c17ada8c930c5c625cd";

// App's computed nullifier (WRONG)
const APP_COMPUTED_NF: &str = "e6b9af67b059407220a0eebff38e51d72cd5e597125065c55b519d342edd7985";
const APP_COMPUTED_POSITION: u64 = 1042059;

// Note parameters from decryption (from z.log)
// diversifier: 69a010e4188a5e15515c48
// value: 1000000 (0.01 ZCL)
const DIVERSIFIER_HEX: &str = "69a010e4188a5e15515c48";
const VALUE: u64 = 1_000_000; // zatoshis

fn main() {
    println!("=== CMU Position Finder & Nullifier Verification ===\n");

    // 1. Decode the spending key
    let (hrp, data, _) = bech32::decode(SPENDING_KEY_BECH32).expect("Invalid Bech32");
    assert_eq!(hrp, "secret-extended-key-main", "Wrong HRP");
    let sk_bytes = Vec::<u8>::from_base32(&data).expect("Invalid base32");
    let extsk = ExtendedSpendingKey::read(&sk_bytes[..]).expect("Failed to parse spending key");
    let dfvk = extsk.to_diversifiable_full_viewing_key();
    let nk = dfvk.fvk().vk.nk;

    println!("✓ Spending key parsed");

    // 2. Convert CMU from display format to wire format
    let cmu_display_bytes = hex::decode(CMU_DISPLAY).expect("Invalid CMU hex");
    let cmu_wire_bytes: Vec<u8> = cmu_display_bytes.iter().rev().cloned().collect();
    println!("\nCMU (display): {}", CMU_DISPLAY);
    println!("CMU (wire):    {}", hex::encode(&cmu_wire_bytes));

    // 3. Load bundled tree and search for CMU
    let tree_path = "/Users/chris/ZipherX/Resources/commitment_tree.bin";
    let tree_data = fs::read(tree_path).expect("Failed to read commitment tree");

    let count = u64::from_le_bytes(tree_data[0..8].try_into().unwrap());
    println!("\nBundled tree: {} CMUs", count);

    // Search for CMU position
    let mut found_position: Option<u64> = None;
    let mut offset = 8;
    for i in 0..count {
        if offset + 32 > tree_data.len() {
            break;
        }
        let cmu = &tree_data[offset..offset + 32];
        if cmu == cmu_wire_bytes.as_slice() {
            found_position = Some(i);
            println!("✓ Found CMU at position {} in bundled tree!", i);
            break;
        }
        offset += 32;
    }

    if found_position.is_none() {
        println!("❌ CMU NOT found in bundled tree");
        println!("   (This means the note is beyond bundled tree height 2,926,122)");
        println!("\n   Need to search chain for the exact position...");
    }

    // 4. Parse diversifier
    let div_bytes = hex::decode(DIVERSIFIER_HEX).expect("Invalid diversifier hex");
    let mut div_array = [0u8; 11];
    div_array.copy_from_slice(&div_bytes);
    let diversifier = Diversifier(div_array);

    println!("\nDiversifier: {}", DIVERSIFIER_HEX);

    // Get payment address
    let payment_address = match dfvk.fvk().vk.to_payment_address(diversifier) {
        Some(addr) => addr,
        None => {
            println!("❌ Invalid diversifier - cannot derive payment address");
            return;
        }
    };
    println!("✓ Payment address derived from diversifier");

    // 5. We need the rcm to compute nullifier
    // The rcm comes from decrypting the note ciphertext
    // Let's try with different positions to see if any produces the expected nullifier

    println!("\n=== Testing Nullifier Computation ===");
    println!("App computed position: {}", APP_COMPUTED_POSITION);
    println!("App computed nullifier: {}", APP_COMPUTED_NF);
    println!("Expected on-chain nullifier: {}", EXPECTED_NF_DISPLAY);

    let expected_nf_wire = reverse_hex(EXPECTED_NF_DISPLAY);
    println!("Expected nullifier (wire): {}", expected_nf_wire);

    println!("\n=== Key Insight ===");
    println!("The nullifier computation requires:");
    println!("  1. nk (from spending key) - ✓ derived");
    println!("  2. position (CMU index in tree) - ❓ might be wrong");
    println!("  3. rho = cm + position * G (internal to zcash_primitives)");
    println!("");
    println!("If position is wrong by even 1, the nullifier will be completely different!");
    println!("");
    println!("Bundled tree ends at position {} (height 2,926,122)", count - 1);
    println!("Note was received at height 2,926,290");
    println!("This means the note's CMU is NOT in the bundled tree.");
    println!("");
    println!("App position {} = bundled count {} + {} added CMUs",
             APP_COMPUTED_POSITION, count, APP_COMPUTED_POSITION - count);

    // Check if the position seems reasonable
    let bundled_height: u64 = 2_926_122;
    let note_height: u64 = 2_926_290;
    let blocks_diff = note_height - bundled_height;
    let cmus_after_bundled = APP_COMPUTED_POSITION - count;

    println!("\nBlocks between bundled height and note: {}", blocks_diff);
    println!("CMUs added (according to app): {}", cmus_after_bundled);
    println!("Average CMUs per block: {:.2}", cmus_after_bundled as f64 / blocks_diff as f64);

    println!("\n=== Diagnosis ===");
    println!("The app computed position {} but this produces nullifier:", APP_COMPUTED_POSITION);
    println!("  {}", APP_COMPUTED_NF);
    println!("When it should be:");
    println!("  {}", EXPECTED_NF_DISPLAY);
    println!("");
    println!("Either:");
    println!("  1. The position is WRONG (most likely)");
    println!("  2. The rcm is WRONG (possible byte order issue)");
    println!("  3. Some other parameter is WRONG");
    println!("");
    println!("To find the correct position, we need to count ALL CMUs from Sapling activation");
    println!("up to and including the note's CMU. This requires full chain data.");
}

fn reverse_hex(hex_str: &str) -> String {
    let bytes = hex::decode(hex_str).expect("Invalid hex");
    let reversed: Vec<u8> = bytes.iter().rev().cloned().collect();
    hex::encode(reversed)
}
