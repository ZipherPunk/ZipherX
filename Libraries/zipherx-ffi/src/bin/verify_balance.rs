//! Balance verification script using local node RPC
//!
//! Scans all Sapling transactions, decrypts notes, tracks spends,
//! and computes the correct balance.
//!
//! Usage:
//!   cargo run --release --bin verify_balance -- <spending_key_bech32>
//!
//! Connects to local node at 127.0.0.1:8232

use std::env;
use std::time::Instant;
use std::collections::{HashMap, HashSet};
use std::io::Write as IoWrite;
use zcash_primitives::{
    consensus::BlockHeight,
    sapling::{
        note_encryption::{try_sapling_note_decryption, PreparedIncomingViewingKey, SaplingDomain},
        keys::FullViewingKey,
        Node, Diversifier, Rseed,
    },
    zip32::sapling::ExtendedSpendingKey,
    merkle_tree::HashSer,
};
use zcash_note_encryption::{EphemeralKeyBytes, ShieldedOutput, ENC_CIPHERTEXT_SIZE};
use bech32::{self, FromBase32, ToBase32, Variant};
use base64::Engine;
use ff::PrimeField;

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

// Note data
#[derive(Debug, Clone)]
struct FoundNote {
    height: u32,
    txid: String,
    output_index: usize,
    value: u64,
    diversifier: [u8; 11],
    rcm: jubjub::Fr,
    cmu: [u8; 32],
    position: u64,
    nullifier: [u8; 32],
    is_spent: bool,
    spent_height: Option<u32>,
}

// RPC client for local node
struct NodeRPC {
    host: String,
    port: u16,
    user: String,
    password: String,
}

impl NodeRPC {
    fn new() -> Self {
        let mut user = "user".to_string();
        let mut password = "password".to_string();
        let mut port = 8232u16;
        let mut config_found = "none";

        // Try multiple config locations
        let home = dirs::home_dir().unwrap_or_default();
        let config_paths = [
            home.join("Library/Application Support/Zclassic/zclassic.conf"),  // macOS Zipher
            home.join(".zclassic/zclassic.conf"),  // Standard Unix
            home.join("AppData/Roaming/Zclassic/zclassic.conf"),  // Windows
        ];

        for conf_path in &config_paths {
            if let Ok(content) = std::fs::read_to_string(conf_path) {
                config_found = conf_path.to_str().unwrap_or("path");
                for line in content.lines() {
                    let line = line.trim();
                    if line.starts_with('#') { continue; }
                    if line.starts_with("rpcuser=") {
                        user = line.trim_start_matches("rpcuser=").trim().to_string();
                    } else if line.starts_with("rpcpassword=") {
                        password = line.trim_start_matches("rpcpassword=").trim().to_string();
                    } else if line.starts_with("rpcport=") {
                        if let Ok(p) = line.trim_start_matches("rpcport=").trim().parse::<u16>() {
                            port = p;
                        }
                    }
                }
                break;  // Stop after first config found
            }
        }

        println!("   Config: {}", config_found);
        println!("   RPC: {}:{} user={}", "127.0.0.1", port, user);

        NodeRPC {
            host: "127.0.0.1".to_string(),
            port,
            user,
            password,
        }
    }

    fn call(&self, method: &str, params: &str) -> Result<serde_json::Value, String> {
        let body = format!(
            r#"{{"jsonrpc":"1.0","id":"rust","method":"{}","params":{}}}"#,
            method, params
        );

        let url = format!("http://{}:{}/", self.host, self.port);
        let auth = base64::engine::general_purpose::STANDARD.encode(format!("{}:{}", self.user, self.password));

        let response = ureq::post(&url)
            .set("Authorization", &format!("Basic {}", auth))
            .set("Content-Type", "application/json")
            .send_string(&body)
            .map_err(|e| format!("Request failed: {}", e))?;

        let response_text = response.into_string()
            .map_err(|e| format!("Read response failed: {}", e))?;

        let result: serde_json::Value = serde_json::from_str(&response_text)
            .map_err(|e| format!("JSON parse error: {} in: {}", e, &response_text[..100.min(response_text.len())]))?;

        if let Some(error) = result.get("error") {
            if !error.is_null() {
                return Err(format!("RPC error: {}", error));
            }
        }

        Ok(result["result"].clone())
    }

    fn get_block_count(&self) -> Result<u32, String> {
        self.call("getblockcount", "[]")?
            .as_u64()
            .map(|n| n as u32)
            .ok_or("Invalid block count".to_string())
    }

    fn get_block_hash(&self, height: u32) -> Result<String, String> {
        self.call("getblockhash", &format!("[{}]", height))?
            .as_str()
            .map(|s| s.to_string())
            .ok_or("Invalid block hash".to_string())
    }

    fn get_block(&self, hash: &str, verbosity: u32) -> Result<serde_json::Value, String> {
        self.call("getblock", &format!(r#"["{}", {}]"#, hash, verbosity))
    }

    fn get_raw_transaction(&self, txid: &str) -> Result<serde_json::Value, String> {
        self.call("getrawtransaction", &format!(r#"["{}", 1]"#, txid))
    }
}

fn decode_spending_key(input: &str) -> Result<ExtendedSpendingKey, String> {
    if input.starts_with("secret-extended-key-main") {
        let (hrp, data, _variant) = bech32::decode(input)
            .map_err(|e| format!("Invalid bech32: {}", e))?;

        if hrp != "secret-extended-key-main" {
            return Err(format!("Wrong HRP: {}", hrp));
        }

        let bytes = Vec::<u8>::from_base32(&data)
            .map_err(|e| format!("Invalid base32: {}", e))?;

        if bytes.len() != 169 {
            return Err(format!("Key must be 169 bytes, got {}", bytes.len()));
        }

        ExtendedSpendingKey::read(&mut &bytes[..])
            .map_err(|e| format!("Parse failed: {:?}", e))
    } else {
        let bytes = hex::decode(input)
            .map_err(|e| format!("Invalid hex: {}", e))?;

        ExtendedSpendingKey::read(&mut &bytes[..])
            .map_err(|e| format!("Parse failed: {:?}", e))
    }
}

fn compute_nullifier(
    extsk: &ExtendedSpendingKey,
    diversifier: &[u8; 11],
    value: u64,
    rcm: &jubjub::Fr,
    position: u64,
) -> [u8; 32] {
    // Get the diversifiable full viewing key
    let dfvk = extsk.to_diversifiable_full_viewing_key();

    // Get the nullifier deriving key (nk) from fvk.vk
    let nk = dfvk.fvk().vk.nk;

    // Parse diversifier
    let div = Diversifier(*diversifier);

    // Get payment address from the viewing key and diversifier
    if let Some(payment_address) = dfvk.fvk().vk.to_payment_address(div) {
        // Create the note using the PaymentAddress convenience method
        let note = payment_address.create_note(value, Rseed::BeforeZip212(*rcm));

        // Compute nullifier using proper PRF_nf
        let nullifier = note.nf(&nk, position);
        nullifier.0
    } else {
        [0u8; 32]
    }
}

fn main() {
    let args: Vec<String> = env::args().collect();

    if args.len() < 2 {
        eprintln!("Usage: {} <spending_key_bech32>", args[0]);
        eprintln!("Example: {} secret-extended-key-main1q0zmr7hf...", args[0]);
        std::process::exit(1);
    }

    let sk_str = &args[1];

    println!("═══════════════════════════════════════════════════════════════");
    println!("  ZipherX Balance Verification Script");
    println!("═══════════════════════════════════════════════════════════════");

    // Decode spending key
    println!("\n[1/6] Decoding spending key...");
    let sk = match decode_spending_key(sk_str) {
        Ok(sk) => sk,
        Err(e) => {
            eprintln!("Error decoding spending key: {}", e);
            std::process::exit(1);
        }
    };

    let dfvk = sk.to_diversifiable_full_viewing_key();
    let fvk = dfvk.fvk();
    let ivk = fvk.vk.ivk();
    let prepared_ivk = PreparedIncomingViewingKey::new(&ivk);

    // Get payment address for display
    let (_, payment_address) = sk.default_address();
    let addr_str = bech32::encode(
        "zs",
        payment_address.to_bytes().to_base32(),
        Variant::Bech32,
    ).unwrap_or_else(|_| "error".to_string());

    println!("   Address: {}...{}", &addr_str[..20], &addr_str[addr_str.len()-10..]);

    // Connect to node
    println!("\n[2/6] Connecting to local node...");
    let rpc = NodeRPC::new();

    let chain_height = match rpc.get_block_count() {
        Ok(h) => h,
        Err(e) => {
            eprintln!("Failed to connect to node: {}", e);
            eprintln!("Make sure zclassicd is running with -rpcallowip=127.0.0.1");
            std::process::exit(1);
        }
    };
    println!("   Chain height: {}", chain_height);

    // Load bundled CMU data for position lookup
    println!("\n[3/6] Loading commitment tree data...");
    let bundled_tree_path = "/Users/chris/ZipherX/Sources/Resources/commitment_tree.bin";
    let cmu_data = match std::fs::read(bundled_tree_path) {
        Ok(data) => data,
        Err(e) => {
            eprintln!("Failed to load bundled tree: {}", e);
            std::process::exit(1);
        }
    };

    let cmu_count = u64::from_le_bytes(cmu_data[0..8].try_into().unwrap());
    println!("   Loaded {} CMUs from bundled tree", cmu_count);

    // Build position map for fast CMU lookups
    let mut cmu_positions: HashMap<[u8; 32], u64> = HashMap::new();

    println!("   Building position map...");
    let build_start = Instant::now();
    for i in 0..cmu_count as usize {
        let offset = 8 + i * 32;
        let cmu_bytes: [u8; 32] = cmu_data[offset..offset+32].try_into().unwrap();
        cmu_positions.insert(cmu_bytes, i as u64);
    }
    println!("   Built position map in {:.2}s", build_start.elapsed().as_secs_f64());

    // Determine scan range
    let sapling_activation = 476969u32;
    let bundled_height = 2926122u32;

    println!("\n[4/6] Scanning blockchain for notes...");
    println!("   Sapling activation: {}", sapling_activation);
    println!("   Bundled tree height: {}", bundled_height);
    println!("   Chain tip: {}", chain_height);

    let mut found_notes: Vec<FoundNote> = Vec::new();
    let mut all_nullifiers: HashSet<[u8; 32]> = HashSet::new();
    let mut our_nullifiers: HashMap<[u8; 32], usize> = HashMap::new(); // nullifier -> note index

    let scan_start = Instant::now();
    let mut blocks_scanned = 0u32;
    let mut txs_scanned = 0u32;
    let mut outputs_checked = 0u64;
    let mut current_position = cmu_count; // For notes after bundled tree

    // Scan from Sapling activation to chain tip
    for height in sapling_activation..=chain_height {
        if height % 10000 == 0 || height == chain_height {
            let elapsed = scan_start.elapsed().as_secs_f64();
            let progress = (height - sapling_activation) as f64 / (chain_height - sapling_activation) as f64 * 100.0;
            let blocks_per_sec = blocks_scanned as f64 / elapsed.max(0.001);
            print!("\r   Progress: {:.1}% | Height: {} | Notes: {} | {:.0} blk/s    ",
                   progress, height, found_notes.len(), blocks_per_sec);
            std::io::stdout().flush().unwrap();
        }

        // Get block
        let block_hash = match rpc.get_block_hash(height) {
            Ok(h) => h,
            Err(_) => continue,
        };

        let block = match rpc.get_block(&block_hash, 1) {
            Ok(b) => b,
            Err(_) => continue,
        };

        blocks_scanned += 1;

        // Get transactions
        let txids = match block["tx"].as_array() {
            Some(txs) => txs.iter().filter_map(|t| t.as_str()).collect::<Vec<_>>(),
            None => continue,
        };

        for txid in txids {
            let tx = match rpc.get_raw_transaction(txid) {
                Ok(t) => t,
                Err(_) => continue,
            };

            txs_scanned += 1;

            // Check shielded spends (for nullifier tracking)
            if let Some(spends) = tx["vShieldedSpend"].as_array() {
                for spend in spends {
                    if let Some(nf_hex) = spend["nullifier"].as_str() {
                        if let Ok(nf_bytes) = hex::decode(nf_hex) {
                            if nf_bytes.len() == 32 {
                                let mut nf: [u8; 32] = [0u8; 32];
                                nf.copy_from_slice(&nf_bytes);
                                all_nullifiers.insert(nf);
                            }
                        }
                    }
                }
            }

            // Check shielded outputs
            if let Some(outputs) = tx["vShieldedOutput"].as_array() {
                for (idx, output) in outputs.iter().enumerate() {
                    outputs_checked += 1;

                    // Parse output fields
                    let cmu_hex = match output["cmu"].as_str() { Some(s) => s, None => continue };
                    let epk_hex = match output["ephemeralKey"].as_str() { Some(s) => s, None => continue };
                    let enc_hex = match output["encCiphertext"].as_str() { Some(s) => s, None => continue };

                    let cmu_display = match hex::decode(cmu_hex) { Ok(b) => b, Err(_) => continue };
                    let epk_display = match hex::decode(epk_hex) { Ok(b) => b, Err(_) => continue };
                    let enc_ciphertext = match hex::decode(enc_hex) { Ok(b) => b, Err(_) => continue };

                    if cmu_display.len() != 32 || epk_display.len() != 32 || enc_ciphertext.len() != ENC_CIPHERTEXT_SIZE {
                        continue;
                    }

                    // Reverse byte order (display -> wire format)
                    let mut cmu: [u8; 32] = [0u8; 32];
                    let mut epk: [u8; 32] = [0u8; 32];
                    for i in 0..32 {
                        cmu[i] = cmu_display[31 - i];
                        epk[i] = epk_display[31 - i];
                    }

                    // Determine position
                    let position = if let Some(&pos) = cmu_positions.get(&cmu) {
                        pos
                    } else if height > bundled_height {
                        // Note after bundled tree - use sequential position
                        let pos = current_position;
                        current_position += 1;
                        pos
                    } else {
                        // CMU should be in bundled tree but isn't found - this is a problem
                        continue;
                    };

                    // Try to decrypt
                    let enc_arr: [u8; ENC_CIPHERTEXT_SIZE] = enc_ciphertext.try_into().unwrap();

                    if let Some((note, _, _memo)) = try_sapling_note_decryption(
                        &ZclassicNetwork,
                        BlockHeight::from_u32(height),
                        &prepared_ivk,
                        &ShieldedOutputData { epk, cmu, enc_ciphertext: enc_arr },
                    ) {
                        // Found a note!
                        let value = note.value().inner();
                        let rcm = note.rcm();

                        // Get diversifier
                        let diversifier = note.recipient().diversifier().0;

                        // Compute nullifier
                        let nullifier = compute_nullifier(&sk, &diversifier, value, &rcm, position);

                        let note_idx = found_notes.len();
                        our_nullifiers.insert(nullifier, note_idx);

                        found_notes.push(FoundNote {
                            height,
                            txid: txid.to_string(),
                            output_index: idx,
                            value,
                            diversifier,
                            rcm,
                            cmu,
                            position,
                            nullifier,
                            is_spent: false,
                            spent_height: None,
                        });
                    }
                }
            }
        }
    }

    println!("\n   Scan complete in {:.2}s", scan_start.elapsed().as_secs_f64());
    println!("   Blocks scanned: {}", blocks_scanned);
    println!("   Transactions: {}", txs_scanned);
    println!("   Outputs checked: {}", outputs_checked);

    // Mark spent notes
    println!("\n[5/6] Detecting spent notes...");
    let mut spent_count = 0;
    for nullifier in &all_nullifiers {
        if let Some(&note_idx) = our_nullifiers.get(nullifier) {
            found_notes[note_idx].is_spent = true;
            spent_count += 1;
        }
    }
    println!("   Found {} spent notes", spent_count);

    // Calculate balance
    println!("\n[6/6] Calculating balance...");
    let mut total_received: u64 = 0;
    let mut total_spent: u64 = 0;
    let mut unspent_count = 0;

    for note in &found_notes {
        total_received += note.value;
        if note.is_spent {
            total_spent += note.value;
        } else {
            unspent_count += 1;
        }
    }

    let balance = total_received - total_spent;

    println!("\n═══════════════════════════════════════════════════════════════");
    println!("  RESULTS");
    println!("═══════════════════════════════════════════════════════════════");
    println!("\n  Total notes found:    {}", found_notes.len());
    println!("  Spent notes:          {}", spent_count);
    println!("  Unspent notes:        {}", unspent_count);
    println!("\n  Total received:       {} zatoshis ({:.8} ZCL)", total_received, total_received as f64 / 100_000_000.0);
    println!("  Total spent:          {} zatoshis ({:.8} ZCL)", total_spent, total_spent as f64 / 100_000_000.0);
    println!("  ─────────────────────────────────────────────────────────────");
    println!("  BALANCE:              {} zatoshis ({:.8} ZCL)", balance, balance as f64 / 100_000_000.0);
    println!("═══════════════════════════════════════════════════════════════");

    // Show note details
    if !found_notes.is_empty() {
        println!("\n  Note Details:");
        println!("  ─────────────────────────────────────────────────────────────");
        for (i, note) in found_notes.iter().enumerate() {
            let status = if note.is_spent { "SPENT" } else { "UNSPENT" };
            println!("  #{:2} | Height {:7} | {:12} sat | {:8.8} ZCL | {} | pos: {}",
                     i + 1, note.height, note.value, note.value as f64 / 100_000_000.0,
                     status, note.position);
        }
    }

    println!("\n═══════════════════════════════════════════════════════════════\n");
}

// Helper struct for decryption
#[derive(Clone)]
struct ShieldedOutputData {
    epk: [u8; 32],
    cmu: [u8; 32],
    enc_ciphertext: [u8; ENC_CIPHERTEXT_SIZE],
}

impl ShieldedOutput<SaplingDomain<ZclassicNetwork>, ENC_CIPHERTEXT_SIZE> for ShieldedOutputData {
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
