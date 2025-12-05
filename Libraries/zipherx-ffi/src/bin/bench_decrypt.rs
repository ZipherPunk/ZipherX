//! Benchmark script for Sapling note decryption performance
//!
//! Tests different strategies:
//! 1. Sequential single decryption (current app approach)
//! 2. Batch decryption using zcash_note_encryption::batch
//! 3. Multi-threaded decryption using Rayon
//! 4. Pre-computed IVK optimization
//!
//! Usage:
//!   cargo run --release --bin bench_decrypt -- <num_outputs>
//!   cargo run --release --bin bench_decrypt -- <spending_key> <num_outputs>
//!
//! Spending key can be:
//!   - Bech32 format: secret-extended-key-main1q0zmr7hf...
//!   - Hex format: 169 bytes (338 hex characters)

use std::env;
use std::time::Instant;
use std::sync::atomic::{AtomicUsize, Ordering};
use zcash_primitives::{
    consensus::BlockHeight,
    sapling::{
        keys::FullViewingKey,
        note_encryption::{try_sapling_note_decryption, try_sapling_compact_note_decryption, PreparedIncomingViewingKey, SaplingDomain},
    },
    zip32::sapling::ExtendedSpendingKey,
};
use zcash_note_encryption::{batch, EphemeralKeyBytes, ShieldedOutput, ENC_CIPHERTEXT_SIZE, COMPACT_NOTE_SIZE};
use rand::rngs::OsRng;
use rand::RngCore;
use rayon::prelude::*;
use bech32::{self, FromBase32};

// Zclassic network parameters
#[derive(Clone, Copy, Debug)]
struct ZclassicNetwork;

impl zcash_primitives::consensus::Parameters for ZclassicNetwork {
    fn activation_height(&self, nu: zcash_primitives::consensus::NetworkUpgrade) -> Option<BlockHeight> {
        use zcash_primitives::consensus::NetworkUpgrade;
        match nu {
            NetworkUpgrade::Overwinter => Some(BlockHeight::from_u32(476969)),
            NetworkUpgrade::Sapling => Some(BlockHeight::from_u32(476969)),
            NetworkUpgrade::ZclassicButtercup => Some(BlockHeight::from_u32(707000)),
            _ => None,
        }
    }
    fn coin_type(&self) -> u32 { 147 }
    fn address_network(&self) -> Option<zcash_address::Network> { Some(zcash_address::Network::Main) }
    fn hrp_sapling_extended_spending_key(&self) -> &str { "secret-extended-key-main" }
    fn hrp_sapling_extended_full_viewing_key(&self) -> &str { "zviews" }
    fn hrp_sapling_payment_address(&self) -> &str { "zs" }
    fn b58_pubkey_address_prefix(&self) -> [u8; 2] { [0x1C, 0xB8] }
    fn b58_script_address_prefix(&self) -> [u8; 2] { [0x1C, 0xBD] }
}

// Fake output for benchmarking (won't actually decrypt, but tests computational overhead)
#[derive(Clone)]
struct FakeShieldedOutput {
    epk: [u8; 32],
    cmu: [u8; 32],
    enc_ciphertext: [u8; ENC_CIPHERTEXT_SIZE],
}

impl ShieldedOutput<SaplingDomain<ZclassicNetwork>, ENC_CIPHERTEXT_SIZE> for FakeShieldedOutput {
    fn ephemeral_key(&self) -> EphemeralKeyBytes {
        EphemeralKeyBytes(self.epk)
    }
    fn cmstar_bytes(&self) -> [u8; 32] {
        self.cmu
    }
    fn enc_ciphertext(&self) -> &[u8; ENC_CIPHERTEXT_SIZE] {
        &self.enc_ciphertext
    }
}

// Compact output for compact decryption benchmark
#[derive(Clone)]
struct FakeCompactOutput {
    epk: [u8; 32],
    cmu: [u8; 32],
    enc_ciphertext: [u8; COMPACT_NOTE_SIZE],
}

impl ShieldedOutput<SaplingDomain<ZclassicNetwork>, COMPACT_NOTE_SIZE> for FakeCompactOutput {
    fn ephemeral_key(&self) -> EphemeralKeyBytes {
        EphemeralKeyBytes(self.epk)
    }
    fn cmstar_bytes(&self) -> [u8; 32] {
        self.cmu
    }
    fn enc_ciphertext(&self) -> &[u8; COMPACT_NOTE_SIZE] {
        &self.enc_ciphertext
    }
}

fn generate_fake_outputs(count: usize) -> Vec<FakeShieldedOutput> {
    let mut outputs = Vec::with_capacity(count);
    let mut rng = OsRng;

    for _ in 0..count {
        let mut epk = [0u8; 32];
        let mut cmu = [0u8; 32];
        let mut enc = [0u8; ENC_CIPHERTEXT_SIZE];
        rng.fill_bytes(&mut epk);
        rng.fill_bytes(&mut cmu);
        rng.fill_bytes(&mut enc);
        outputs.push(FakeShieldedOutput {
            epk,
            cmu,
            enc_ciphertext: enc,
        });
    }
    outputs
}

fn generate_compact_outputs(count: usize) -> Vec<FakeCompactOutput> {
    let mut outputs = Vec::with_capacity(count);
    let mut rng = OsRng;

    for _ in 0..count {
        let mut epk = [0u8; 32];
        let mut cmu = [0u8; 32];
        let mut enc = [0u8; COMPACT_NOTE_SIZE];
        rng.fill_bytes(&mut epk);
        rng.fill_bytes(&mut cmu);
        rng.fill_bytes(&mut enc);
        outputs.push(FakeCompactOutput {
            epk,
            cmu,
            enc_ciphertext: enc,
        });
    }
    outputs
}

/// Decode a spending key from either bech32 or hex format
fn decode_spending_key(input: &str) -> Result<ExtendedSpendingKey, String> {
    // Check if it looks like bech32 (starts with "secret-extended-key-main")
    if input.starts_with("secret-extended-key-main") {
        // Bech32 decode
        let (hrp, data, _variant) = bech32::decode(input)
            .map_err(|e| format!("Invalid bech32 encoding: {}", e))?;

        if hrp != "secret-extended-key-main" {
            return Err(format!("Wrong HRP: expected 'secret-extended-key-main', got '{}'", hrp));
        }

        let bytes = Vec::<u8>::from_base32(&data)
            .map_err(|e| format!("Invalid base32 data: {}", e))?;

        if bytes.len() != 169 {
            return Err(format!("Spending key must be 169 bytes, got {}", bytes.len()));
        }

        ExtendedSpendingKey::read(&mut &bytes[..])
            .map_err(|e| format!("Failed to parse spending key: {:?}", e))
    } else {
        // Try hex decode
        let bytes = hex::decode(input)
            .map_err(|e| format!("Invalid hex encoding: {}", e))?;

        if bytes.len() != 169 {
            return Err(format!("Spending key must be 169 bytes, got {}", bytes.len()));
        }

        ExtendedSpendingKey::read(&mut &bytes[..])
            .map_err(|e| format!("Failed to parse spending key: {:?}", e))
    }
}

fn main() {
    let args: Vec<String> = env::args().collect();

    let (extsk, num_outputs) = if args.len() >= 3 {
        // Use provided spending key (bech32 or hex)
        let sk_input = &args[1];
        let num_outputs: usize = args[2].parse().expect("Invalid number of outputs");

        let extsk = decode_spending_key(sk_input).unwrap_or_else(|e| {
            eprintln!("Error decoding spending key: {}", e);
            std::process::exit(1);
        });

        println!("Spending key decoded successfully (format: {})",
            if sk_input.starts_with("secret-extended-key-main") { "bech32" } else { "hex" });
        (extsk, num_outputs)
    } else if args.len() == 2 {
        // Generate random key, use provided output count
        let num_outputs: usize = args[1].parse().expect("Invalid number of outputs");
        println!("No spending key provided, generating random key for benchmarking...");
        let extsk = ExtendedSpendingKey::master(&[0u8; 32]); // Deterministic seed for reproducibility
        (extsk, num_outputs)
    } else {
        eprintln!("Usage: {} [spending_key] <num_outputs>", args[0]);
        eprintln!("");
        eprintln!("Spending key can be in bech32 or hex format:");
        eprintln!("  - bech32: secret-extended-key-main1q0zmr7hf...");
        eprintln!("  - hex: 169 bytes (338 hex characters)");
        eprintln!("");
        eprintln!("Examples:");
        eprintln!("  {} 10000                              # Use random key, 10000 outputs", args[0]);
        eprintln!("  {} secret-extended-key-main1... 10000 # Use bech32 key", args[0]);
        eprintln!("  {} $(cat ~/.zipherx_sk) 10000         # Use hex key from file", args[0]);
        std::process::exit(1);
    };

    println!("=== Sapling Note Decryption Benchmark ===");
    println!("Spending key loaded successfully");
    println!("Testing with {} fake shielded outputs", num_outputs);
    println!("");

    // Generate fake outputs
    println!("Generating {} fake outputs...", num_outputs);
    let start = Instant::now();
    let outputs = generate_fake_outputs(num_outputs);
    let compact_outputs = generate_compact_outputs(num_outputs);
    println!("Generated in {:?}", start.elapsed());
    println!("");

    // Derive IVK once
    let fvk = FullViewingKey::from_expanded_spending_key(&extsk.expsk);
    let ivk = fvk.vk.ivk();
    let prepared_ivk = PreparedIncomingViewingKey::new(&ivk);

    let height = BlockHeight::from_u32(2930000);

    // === Benchmark 1: Sequential single decryption (current approach) ===
    println!("--- Benchmark 1: Sequential Single Decryption ---");
    let start = Instant::now();
    let mut decrypted_count = 0;

    for output in &outputs {
        // This is what the current app does
        let result = try_sapling_note_decryption(&ZclassicNetwork, height, &prepared_ivk, output);
        if result.is_some() {
            decrypted_count += 1;
        }
    }

    let elapsed = start.elapsed();
    let per_output = elapsed.as_micros() as f64 / num_outputs as f64;
    println!("Time: {:?} ({:.2} us/output)", elapsed, per_output);
    println!("Decrypted: {} (expected 0 for fake data)", decrypted_count);
    println!("");

    // === Benchmark 2: Sequential compact decryption ===
    println!("--- Benchmark 2: Sequential Compact Decryption ---");
    let start = Instant::now();
    let mut decrypted_count = 0;

    for output in &compact_outputs {
        let result = try_sapling_compact_note_decryption(&ZclassicNetwork, height, &prepared_ivk, output);
        if result.is_some() {
            decrypted_count += 1;
        }
    }

    let elapsed = start.elapsed();
    let per_output = elapsed.as_micros() as f64 / num_outputs as f64;
    println!("Time: {:?} ({:.2} us/output)", elapsed, per_output);
    println!("Decrypted: {}", decrypted_count);
    println!("");

    // === Benchmark 3: Batch decryption ===
    println!("--- Benchmark 3: Batch Decryption (zcash_note_encryption::batch) ---");
    let start = Instant::now();

    // Prepare batch inputs: (domain, output) tuples
    let batch_inputs: Vec<_> = outputs.iter()
        .map(|output| {
            let domain = SaplingDomain::for_height(ZclassicNetwork, height);
            (domain, output.clone())
        })
        .collect();

    // IVKs slice
    let ivks = [prepared_ivk.clone()];

    // Run batch decryption
    let results = batch::try_note_decryption(&ivks, &batch_inputs);
    let decrypted_count = results.iter().filter(|r| r.is_some()).count();

    let elapsed = start.elapsed();
    let per_output = elapsed.as_micros() as f64 / num_outputs as f64;
    println!("Time: {:?} ({:.2} us/output)", elapsed, per_output);
    println!("Decrypted: {}", decrypted_count);
    println!("");

    // === Benchmark 4: Batch compact decryption ===
    println!("--- Benchmark 4: Batch Compact Decryption ---");
    let start = Instant::now();

    let compact_batch_inputs: Vec<_> = compact_outputs.iter()
        .map(|output| {
            let domain = SaplingDomain::for_height(ZclassicNetwork, height);
            (domain, output.clone())
        })
        .collect();

    let results = batch::try_compact_note_decryption(&ivks, &compact_batch_inputs);
    let decrypted_count = results.iter().filter(|r| r.is_some()).count();

    let elapsed = start.elapsed();
    let per_output = elapsed.as_micros() as f64 / num_outputs as f64;
    println!("Time: {:?} ({:.2} us/output)", elapsed, per_output);
    println!("Decrypted: {}", decrypted_count);
    println!("");

    // === Benchmark 5: Rayon parallel decryption ===
    println!("--- Benchmark 5: Rayon Parallel Decryption ---");
    let start = Instant::now();
    let decrypted_count = AtomicUsize::new(0);

    outputs.par_iter().for_each(|output| {
        let result = try_sapling_note_decryption(&ZclassicNetwork, height, &prepared_ivk, output);
        if result.is_some() {
            decrypted_count.fetch_add(1, Ordering::Relaxed);
        }
    });

    let elapsed = start.elapsed();
    let per_output = elapsed.as_micros() as f64 / num_outputs as f64;
    println!("Time: {:?} ({:.2} us/output)", elapsed, per_output);
    println!("Decrypted: {}", decrypted_count.load(Ordering::Relaxed));
    println!("Threads: {} (Rayon default)", rayon::current_num_threads());
    println!("");

    // === Benchmark 6: Rayon parallel with chunks (block simulation) ===
    println!("--- Benchmark 6: Rayon Parallel Chunks (block simulation) ---");
    let start = Instant::now();
    let decrypted_count = AtomicUsize::new(0);

    // Simulate blocks with ~10 outputs each (realistic scenario)
    let chunk_size = 10;
    let chunks: Vec<_> = outputs.chunks(chunk_size).collect();

    chunks.par_iter().for_each(|chunk| {
        // Each "block" processes its outputs sequentially within the parallel task
        for output in *chunk {
            let result = try_sapling_note_decryption(&ZclassicNetwork, height, &prepared_ivk, output);
            if result.is_some() {
                decrypted_count.fetch_add(1, Ordering::Relaxed);
            }
        }
    });

    let elapsed = start.elapsed();
    let per_output = elapsed.as_micros() as f64 / num_outputs as f64;
    let num_chunks = chunks.len();
    println!("Time: {:?} ({:.2} us/output)", elapsed, per_output);
    println!("Decrypted: {}", decrypted_count.load(Ordering::Relaxed));
    println!("Chunks: {} (simulated blocks with {} outputs each)", num_chunks, chunk_size);
    println!("");

    // === Benchmark 7: Rayon parallel compact decryption ===
    println!("--- Benchmark 7: Rayon Parallel Compact Decryption ---");
    let start = Instant::now();
    let decrypted_count = AtomicUsize::new(0);

    compact_outputs.par_iter().for_each(|output| {
        let result = try_sapling_compact_note_decryption(&ZclassicNetwork, height, &prepared_ivk, output);
        if result.is_some() {
            decrypted_count.fetch_add(1, Ordering::Relaxed);
        }
    });

    let elapsed = start.elapsed();
    let per_output = elapsed.as_micros() as f64 / num_outputs as f64;
    println!("Time: {:?} ({:.2} us/output)", elapsed, per_output);
    println!("Decrypted: {}", decrypted_count.load(Ordering::Relaxed));
    println!("Threads: {} (Rayon default)", rayon::current_num_threads());
    println!("");

    // === Summary ===
    println!("=== Summary ===");
    println!("For {} outputs:", num_outputs);
    println!("");
    println!("Key insights:");
    println!("1. PreparedIncomingViewingKey should be computed ONCE and reused");
    println!("2. Compact decryption is faster (no memo decryption)");
    println!("3. Batch APIs may not help much for single IVK (designed for multi-IVK)");
    println!("4. Rayon parallel can use all CPU cores for massive speedup");
    println!("5. Chunk-based parallel (per-block) is ideal for scanning");
    println!("");
    println!("The actual decryption bottleneck is:");
    println!("- ECDH key agreement: ~200-500us per output (jubjub scalar mult)");
    println!("- ChaCha20-Poly1305 decrypt: ~1-5us per output");
    println!("");
    println!("To improve scanning performance:");
    println!("1. Use compact decryption (skip memo until note found)");
    println!("2. Pre-cache the PreparedIncomingViewingKey");
    println!("3. Multi-thread across blocks (not within blocks)");
    println!("4. Parallel fetch + parallel decrypt pipeline");
    println!("5. Use BIP-158 compact filters to skip empty blocks");
}
