/// Full nullifier verification test
/// Tests: spending key → note decryption → position lookup → nullifier computation
/// Compares with actual on-chain nullifier

use zcash_primitives::sapling::PaymentAddress;
use zcash_primitives::zip32::ExtendedSpendingKey;
use bech32::{self, FromBase32, ToBase32};
use group::GroupEncoding;

const SPENDING_KEY_BECH32: &str = "***REDACTED-SPENDING-KEY***";

// Expected on-chain nullifier for the first note (0.01 ZCL at height 2926290)
// This nullifier appears in the vShieldedSpend of tx 63038d91a05e6ec5359f5ccc5e09624fec0d61e6e050b25377eb48beb5f946f7
const EXPECTED_NULLIFIER_DISPLAY: &str = "c74900d8932caf653e2063f1b3338ab73101e73d18492c17ada8c930c5c625cd";

// App's computed nullifier (WRONG - doesn't match)
const APP_COMPUTED_NULLIFIER: &str = "e6b9af67b059407220a0eebff38e51d72cd5e597125065c55b519d342edd7985";
const APP_COMPUTED_POSITION: u64 = 1042059;

fn main() {
    println!("=== Full Nullifier Verification Test ===\n");

    // 1. Decode the spending key
    let (hrp, data, _) = bech32::decode(SPENDING_KEY_BECH32).expect("Invalid Bech32");
    assert_eq!(hrp, "secret-extended-key-main", "Wrong HRP");
    let sk_bytes = Vec::<u8>::from_base32(&data).expect("Invalid base32");

    let extsk = ExtendedSpendingKey::read(&sk_bytes[..]).expect("Failed to parse spending key");
    let dfvk = extsk.to_diversifiable_full_viewing_key();
    let nk = dfvk.fvk().vk.nk;

    println!("✓ Spending key decoded");
    println!("  nk (nullifier key): {:?}", nk);

    // 2. Get the default payment address
    let (_, default_address) = extsk.default_address();
    let default_diversifier = default_address.diversifier();
    println!("\n✓ Default address:");
    println!("  diversifier: {}", hex::encode(default_diversifier.0));

    // 3. Test nullifier computation with known values
    // Let's manually compute a nullifier to verify the formula

    // First, check the app's computed position
    println!("\n=== App Computed Values ===");
    println!("Position: {}", APP_COMPUTED_POSITION);
    println!("App computed nullifier: {}", APP_COMPUTED_NULLIFIER);
    println!("Expected nullifier (display): {}", EXPECTED_NULLIFIER_DISPLAY);

    let expected_wire = reverse_hex(EXPECTED_NULLIFIER_DISPLAY);
    println!("Expected nullifier (wire): {}", expected_wire);

    // These don't match, so something is fundamentally wrong
    if APP_COMPUTED_NULLIFIER != EXPECTED_NULLIFIER_DISPLAY && APP_COMPUTED_NULLIFIER != expected_wire {
        println!("\n❌ App nullifier doesn't match expected (neither display nor wire format)");
        println!("   This means one of: diversifier, value, rcm, or position is WRONG");
    }

    // 4. Let's verify by computing with our code
    // We need the decrypted note data (diversifier, value, rcm)
    // Since we don't have it, let's at least verify the spending key derivation

    println!("\n=== Verification of Key Derivation ===");

    // Check that nk can be serialized
    let nk_bytes = nk.0.to_bytes();
    println!("nk bytes: {}", hex::encode(&nk_bytes));

    // The nullifier computation in zcash_primitives uses:
    // nf = PRF_nf(nk, rho) where rho = cm + position
    // This is complex and depends on the exact note parameters

    println!("\n=== Possible Causes ===");
    println!("1. DIVERSIFIER: The decrypted diversifier might not match the address diversifier");
    println!("2. POSITION: Position {} might be wrong (off by even 1 = completely different nf)", APP_COMPUTED_POSITION);
    println!("3. RCM: The note commitment randomness might have byte order issues");
    println!("4. VALUE: Value is probably correct (1000000 zatoshis = 0.01 ZCL)");

    // 5. Let's check if the position is even in the right ballpark
    let bundled_cmu_count = 1_041_891u64;
    let bundled_tree_height = 2_926_122u64;
    let note_height = 2_926_290u64;

    let cmus_after_bundled = APP_COMPUTED_POSITION - bundled_cmu_count;
    let blocks_after_bundled = note_height - bundled_tree_height;

    println!("\n=== Position Analysis ===");
    println!("Bundled tree: {} CMUs at height {}", bundled_cmu_count, bundled_tree_height);
    println!("Note height: {}", note_height);
    println!("App computed position: {}", APP_COMPUTED_POSITION);
    println!("CMUs added after bundled: {}", cmus_after_bundled);
    println!("Blocks after bundled: {}", blocks_after_bundled);
    println!("Average: {:.2} CMUs/block", cmus_after_bundled as f64 / blocks_after_bundled as f64);

    // The position SEEMS reasonable (168 CMUs in 168 blocks)
    // But even being off by 1 would completely change the nullifier

    println!("\n=== Conclusion ===");
    println!("The position calculation SEEMS reasonable, but nullifier is still wrong.");
    println!("Most likely cause: POSITION is off by some amount.");
    println!("");
    println!("To verify, we need to find the EXACT position of the note's CMU in the blockchain.");
    println!("This requires iterating through ALL blocks from Sapling activation and counting CMUs.");
    println!("");
    println!("Alternatively, check if the spending key generates the CORRECT payment address.");

    // Verify the address
    let addr_bech32 = address_to_bech32(&default_address);
    println!("\nDerived address: {}", addr_bech32);
    println!("Expected:        zs1dxsppeqc3f0p252ufzfvjfvk6k76yh92fsfu7dznesg4uc48u0j4kv96y5mtmzm582dr742wf4q");
}

fn reverse_hex(hex_str: &str) -> String {
    let bytes = hex::decode(hex_str).expect("Invalid hex");
    let reversed: Vec<u8> = bytes.iter().rev().cloned().collect();
    hex::encode(reversed)
}

fn address_to_bech32(addr: &PaymentAddress) -> String {
    let addr_bytes = addr.to_bytes();
    let slice: &[u8] = &addr_bytes;
    bech32::encode("zs", slice.to_base32(), bech32::Variant::Bech32).unwrap()
}
