//! ZipherX FFI - C bindings for Sapling cryptography
//!
//! This crate provides C-compatible functions for iOS integration
//! Using real librustzcash for proper Sapling operations

// Set to true for verbose debug output, false for production
const DEBUG_LOGGING: bool = false;

// Macro for conditional debug output
macro_rules! debug_log {
    ($($arg:tt)*) => {
        if DEBUG_LOGGING {
            eprintln!($($arg)*);
        }
    };
}

use std::slice;
use std::sync::Mutex;
use std::path::Path;
use bip0039::{Count, English, Mnemonic};
use bech32::{ToBase32, FromBase32, Variant};

use zcash_primitives::{
    consensus::{Parameters, MainNetwork, BlockHeight, NetworkUpgrade},
    sapling::{
        keys::{FullViewingKey, OutgoingViewingKey},
        Diversifier, PaymentAddress,
        value::NoteValue,
        Rseed,
        note_encryption::{try_sapling_note_decryption, try_sapling_output_recovery, PreparedIncomingViewingKey, SaplingDomain},
    },
    zip32::{ChildIndex, sapling::ExtendedSpendingKey},
    transaction::{
        builder::Builder,
        components::Amount,
    },
    memo::MemoBytes,
};
use zcash_note_encryption::{EphemeralKeyBytes, ShieldedOutput, ENC_CIPHERTEXT_SIZE, Domain};
use chacha20poly1305::{ChaCha20Poly1305, KeyInit, aead::Aead};
use chacha20poly1305::aead::generic_array::GenericArray;
use incrementalmerkletree::{MerklePath, Position, frontier::CommitmentTree, witness::IncrementalWitness, Hashable};
use zcash_primitives::merkle_tree::{read_commitment_tree, write_commitment_tree, read_incremental_witness, write_incremental_witness, HashSer};
use zcash_proofs::prover::LocalTxProver;
use group::{GroupEncoding, cofactor::CofactorGroup, Curve};
use ff::{PrimeField, Field};
use rand::rngs::OsRng;

// Global prover instance
static PROVER: Mutex<Option<LocalTxProver>> = Mutex::new(None);

// Sapling tree depth
const SAPLING_COMMITMENT_TREE_DEPTH: u8 = 32;

// Zclassic network parameters
#[derive(Clone, Copy, Debug)]
struct ZclassicNetwork;

impl Parameters for ZclassicNetwork {
    fn activation_height(&self, nu: NetworkUpgrade) -> Option<BlockHeight> {
        // Zclassic-specific activation heights
        // Using local fork of zcash_primitives with ZclassicButtercup branch ID (0x930b540d)
        //
        // Zclassic activation heights from chainparams.cpp:
        // - Overwinter: 476,969
        // - Sapling: 476,969
        // - Bubbles: 585,318 (Zclassic-specific, branch ID 0x821a451c)
        // - Buttercup: 707,000 (Zclassic-specific, branch ID 0x930b540d) - CURRENTLY ACTIVE
        match nu {
            NetworkUpgrade::Overwinter => Some(BlockHeight::from_u32(476969)),
            NetworkUpgrade::Sapling => Some(BlockHeight::from_u32(476969)),
            // Skip Blossom/Heartwood - these are Zcash-specific with wrong branch IDs
            NetworkUpgrade::Blossom => None,
            NetworkUpgrade::Heartwood => None,
            NetworkUpgrade::Canopy => None,
            NetworkUpgrade::Nu5 => None,
            // ZclassicButtercup uses the correct branch ID (0x930b540d)
            NetworkUpgrade::ZclassicButtercup => Some(BlockHeight::from_u32(707000)),
            #[allow(unreachable_patterns)]
            _ => None,
        }
    }

    fn coin_type(&self) -> u32 {
        147 // ZCL coin type
    }

    fn address_network(&self) -> Option<zcash_address::Network> {
        Some(zcash_address::Network::Main)
    }

    fn hrp_sapling_extended_spending_key(&self) -> &str {
        "secret-extended-key-main"
    }

    fn hrp_sapling_extended_full_viewing_key(&self) -> &str {
        "zviews"
    }

    fn hrp_sapling_payment_address(&self) -> &str {
        "zs"
    }

    fn b58_pubkey_address_prefix(&self) -> [u8; 2] {
        [0x1C, 0xB8] // Zclassic t1 prefix
    }

    fn b58_script_address_prefix(&self) -> [u8; 2] {
        [0x1C, 0xBD] // Zclassic t3 prefix
    }
}


// =============================================================================
// Mnemonic Generation
// =============================================================================

/// Generate a 24-word BIP-39 mnemonic
#[no_mangle]
pub unsafe extern "C" fn zipherx_generate_mnemonic(output: *mut u8) -> usize {
    let mnemonic: Mnemonic<English> = Mnemonic::generate(Count::Words24);

    let phrase = mnemonic.phrase();
    let bytes = phrase.as_bytes();

    if bytes.len() > 256 {
        return 0;
    }

    std::ptr::copy_nonoverlapping(bytes.as_ptr(), output, bytes.len());
    bytes.len()
}

/// Validate a BIP-39 mnemonic
#[no_mangle]
pub unsafe extern "C" fn zipherx_validate_mnemonic(mnemonic: *const i8) -> bool {
    let c_str = match std::ffi::CStr::from_ptr(mnemonic).to_str() {
        Ok(s) => s,
        Err(_) => return false,
    };

    Mnemonic::<English>::from_phrase(c_str).is_ok()
}

/// Derive seed from mnemonic (PBKDF2-SHA512)
#[no_mangle]
pub unsafe extern "C" fn zipherx_mnemonic_to_seed(
    mnemonic: *const i8,
    output: *mut u8,
) -> bool {
    let phrase = match std::ffi::CStr::from_ptr(mnemonic).to_str() {
        Ok(s) => s,
        Err(_) => return false,
    };

    let mnemonic: Mnemonic<English> = match Mnemonic::from_phrase(phrase) {
        Ok(m) => m,
        Err(_) => return false,
    };

    let seed = mnemonic.to_seed("");
    std::ptr::copy_nonoverlapping(seed.as_ptr(), output, 64);
    true
}

// =============================================================================
// Key Derivation - Real ZIP-32 Implementation
// =============================================================================

/// Derive extended spending key from seed using ZIP-32
/// Stores the full 169-byte serialized ExtendedSpendingKey
#[no_mangle]
pub unsafe extern "C" fn zipherx_derive_spending_key(
    seed: *const u8,
    account: u32,
    sk_out: *mut u8,
) -> bool {
    let seed_slice = slice::from_raw_parts(seed, 64);

    // Derive master extended spending key using ZIP-32
    let master = ExtendedSpendingKey::master(seed_slice);

    // Derive to account level: m/32'/147'/account'
    let account_key = master
        .derive_child(ChildIndex::Hardened(32))
        .derive_child(ChildIndex::Hardened(147))
        .derive_child(ChildIndex::Hardened(account));

    // Serialize the full ExtendedSpendingKey (169 bytes)
    // This includes: depth, parent_fvk_tag, child_index, chain_code, expsk, dk
    let mut serialized = Vec::new();
    account_key.write(&mut serialized).unwrap();

    if serialized.len() != 169 {
        return false;
    }

    std::ptr::copy_nonoverlapping(serialized.as_ptr(), sk_out, 169);

    true
}

/// Derive payment address from serialized ExtendedSpendingKey (169 bytes)
#[no_mangle]
pub unsafe extern "C" fn zipherx_derive_address(
    sk: *const u8,
    diversifier_index: u64,
    address_out: *mut u8,
) -> bool {
    let sk_slice = slice::from_raw_parts(sk, 169);

    // Deserialize the ExtendedSpendingKey
    let account_key = match ExtendedSpendingKey::read(&mut &sk_slice[..]) {
        Ok(key) => key,
        Err(_) => return false,
    };

    // Get default address (uses diversifier index 0 by default)
    // or find address at specific index
    let (_, addr) = if diversifier_index == 0 {
        account_key.default_address()
    } else {
        // For non-zero index, we need to use the diversifier key
        // For now, just use default
        account_key.default_address()
    };

    // Serialize address: diversifier (11) + pk_d (32) = 43 bytes
    let addr_bytes = addr.to_bytes();

    std::ptr::copy_nonoverlapping(addr_bytes.as_ptr(), address_out, 43);

    true
}

/// Derive incoming viewing key from serialized ExtendedSpendingKey (169 bytes)
#[no_mangle]
pub unsafe extern "C" fn zipherx_derive_ivk(
    sk: *const u8,
    ivk_out: *mut u8,
) -> bool {
    let sk_slice = slice::from_raw_parts(sk, 169);

    // Deserialize the ExtendedSpendingKey
    let account_key = match ExtendedSpendingKey::read(&mut &sk_slice[..]) {
        Ok(key) => key,
        Err(_) => return false,
    };

    // Derive full viewing key from expanded spending key
    let fvk = FullViewingKey::from_expanded_spending_key(&account_key.expsk);
    let ivk = fvk.vk.ivk();

    let ivk_bytes = ivk.to_repr();
    std::ptr::copy_nonoverlapping(ivk_bytes.as_ptr(), ivk_out, 32);

    true
}


/// Compute nullifier for a note using proper Sapling cryptography
/// Requires the spending key (169 bytes) to derive nk for PRF_nf
#[no_mangle]
pub unsafe extern "C" fn zipherx_compute_nullifier(
    spending_key: *const u8,  // Extended spending key (169 bytes)
    diversifier: *const u8,
    value: u64,
    rcm: *const u8,
    position: u64,
    nf_out: *mut u8,
) -> bool {
    use zcash_primitives::sapling::{Diversifier, Rseed};
    use zcash_primitives::zip32::ExtendedSpendingKey;
    use jubjub::Fr;
    use ff::PrimeField;

    let sk_slice = slice::from_raw_parts(spending_key, 169);
    let div_slice = slice::from_raw_parts(diversifier, 11);
    let rcm_slice = slice::from_raw_parts(rcm, 32);

    // Parse the extended spending key
    let extsk = match ExtendedSpendingKey::read(&sk_slice[..]) {
        Ok(k) => k,
        Err(e) => {
            eprintln!("Failed to parse spending key for nullifier: {:?}", e);
            return false;
        }
    };

    // Get the diversifiable full viewing key
    let dfvk = extsk.to_diversifiable_full_viewing_key();

    // Get the nullifier deriving key (nk) from fvk.vk
    let nk = dfvk.fvk().vk.nk;

    // Parse diversifier
    let mut div_bytes = [0u8; 11];
    div_bytes.copy_from_slice(div_slice);
    let diversifier = Diversifier(div_bytes);

    // Get payment address from the viewing key and diversifier
    let payment_address = match dfvk.fvk().vk.to_payment_address(diversifier) {
        Some(addr) => addr,
        None => {
            eprintln!("Invalid diversifier for nullifier computation");
            return false;
        }
    };

    // Parse rcm as a scalar
    let mut rcm_bytes = [0u8; 32];
    rcm_bytes.copy_from_slice(rcm_slice);
    let rcm_scalar: Fr = match Option::<Fr>::from(Fr::from_repr(rcm_bytes)) {
        Some(r) => r,
        None => {
            eprintln!("Invalid rcm for nullifier computation");
            return false;
        }
    };

    // Create the note using the PaymentAddress convenience method
    let note = payment_address.create_note(value, Rseed::BeforeZip212(rcm_scalar));

    // Compute nullifier using proper PRF_nf
    let nullifier = note.nf(&nk, position);

    // Copy nullifier to output
    std::ptr::copy_nonoverlapping(nullifier.0.as_ptr(), nf_out, 32);

    true
}

// =============================================================================
// Address Operations
// =============================================================================

/// Encode address bytes as Zclassic z-address string using Bech32
#[no_mangle]
pub unsafe extern "C" fn zipherx_encode_address(
    address: *const u8,
    output: *mut u8,
) -> usize {
    let addr_slice = slice::from_raw_parts(address, 43);

    // Encode using Bech32 with "zs" prefix (Zclassic Sapling)
    let encoded = match bech32::encode("zs", addr_slice.to_base32(), Variant::Bech32) {
        Ok(s) => s,
        Err(_) => return 0,
    };

    let bytes = encoded.as_bytes();

    std::ptr::copy_nonoverlapping(bytes.as_ptr(), output, bytes.len());
    bytes.len()
}

/// Decode Zclassic z-address string to bytes
#[no_mangle]
pub unsafe extern "C" fn zipherx_decode_address(
    address_str: *const i8,
    output: *mut u8,
) -> bool {
    let addr = match std::ffi::CStr::from_ptr(address_str).to_str() {
        Ok(s) => s,
        Err(_) => return false,
    };

    // Decode Bech32
    let (hrp, data, _variant) = match bech32::decode(addr) {
        Ok(d) => d,
        Err(_) => return false,
    };

    // Must have "zs" prefix for Zclassic Sapling
    if hrp != "zs" {
        return false;
    }

    // Convert from base32 to bytes
    let bytes = match Vec::<u8>::from_base32(&data) {
        Ok(b) if b.len() == 43 => b,
        _ => return false,
    };

    // Debug: print the diversifier from this address
    debug_log!("DEBUG decode_address: diversifier = {:02x?}", &bytes[0..11]);

    std::ptr::copy_nonoverlapping(bytes.as_ptr(), output, 43);
    true
}

/// Validate a z-address
#[no_mangle]
pub unsafe extern "C" fn zipherx_validate_address(address_str: *const i8) -> bool {
    let addr = match std::ffi::CStr::from_ptr(address_str).to_str() {
        Ok(s) => s,
        Err(_) => return false,
    };

    // Decode and validate Bech32
    let (hrp, data, _variant) = match bech32::decode(addr) {
        Ok(d) => d,
        Err(_) => return false,
    };

    // Must have "zs" prefix for Zclassic Sapling
    if hrp != "zs" {
        return false;
    }

    // Convert from base32 and check length
    match Vec::<u8>::from_base32(&data) {
        Ok(b) => b.len() == 43,
        Err(_) => false,
    }
}

// =============================================================================
// Note Decryption - Manual ChaCha20Poly1305 Implementation
// =============================================================================

/// Try to decrypt a Sapling note using incoming viewing key
/// Uses manual implementation matching zcash_primitives exactly
#[no_mangle]
pub unsafe extern "C" fn zipherx_try_decrypt_note(
    ivk: *const u8,
    epk: *const u8,
    cmu: *const u8,
    ciphertext: *const u8,
    output: *mut u8,
) -> usize {
    use chacha20poly1305::{ChaCha20Poly1305, Key, Nonce, aead::Aead, KeyInit};

    let ivk_slice = slice::from_raw_parts(ivk, 32);
    let epk_slice = slice::from_raw_parts(epk, 32);
    let _cmu_slice = slice::from_raw_parts(cmu, 32);
    let ciphertext_slice = slice::from_raw_parts(ciphertext, 580);

    // Parse ivk as scalar
    let mut ivk_bytes = [0u8; 32];
    ivk_bytes.copy_from_slice(ivk_slice);

    let ivk_scalar: jubjub::Fr = match Option::<jubjub::Fr>::from(jubjub::Fr::from_repr(ivk_bytes)) {
        Some(f) => f,
        None => {
            return 0;
        }
    };

    // Parse ephemeral key as ExtendedPoint
    let mut epk_bytes = [0u8; 32];
    epk_bytes.copy_from_slice(epk_slice);

    let epk: jubjub::ExtendedPoint = match Option::<jubjub::ExtendedPoint>::from(jubjub::ExtendedPoint::from_bytes(&epk_bytes)) {
        Some(p) => p,
        None => {
            return 0;
        }
    };

    // Derive shared secret: Ka = [8 * ivk] epk (cofactor clearing)
    // This is per zcash_primitives spec.rs ka_sapling_agree_prepared
    let ka = epk * ivk_scalar;
    let ka_cleared = ka.clear_cofactor();  // Multiply by cofactor 8

    // Convert SubgroupPoint to ExtendedPoint, then to AffinePoint
    let ka_extended: jubjub::ExtendedPoint = ka_cleared.into();
    let ka_affine = ka_extended.to_affine();
    // Use compressed point encoding (v with sign bit for u) per zcash_primitives
    let ka_bytes = ka_affine.to_bytes();

    // KDF: symmetric_key = BLAKE2b-256(personalization="Zcash_SaplingKDF", dhsecret || epk)
    // Per zcash_primitives/src/sapling/keys.rs lines 464-470
    let mut kdf_hasher = blake2b_simd::Params::new()
        .hash_length(32)
        .personal(b"Zcash_SaplingKDF")
        .to_state();
    kdf_hasher.update(&ka_bytes);
    kdf_hasher.update(&epk_bytes);
    let symmetric_key = kdf_hasher.finalize();

    // Decrypt with ChaCha20Poly1305
    let key = Key::from_slice(symmetric_key.as_bytes());
    let cipher = ChaCha20Poly1305::new(key);
    let nonce = Nonce::from_slice(&[0u8; 12]);

    // Ciphertext is 580 bytes: 564 encrypted + 16 tag
    let decrypted = match cipher.decrypt(nonce, &ciphertext_slice[..580]) {
        Ok(p) => p,
        Err(_) => {
            return 0;
        }
    };

    if decrypted.len() < 51 {
        return 0;
    }

    // Copy to output: diversifier(11) || value(8) || rcm(32) || memo(512)
    let out_len = decrypted.len().min(564);
    std::ptr::copy_nonoverlapping(decrypted.as_ptr(), output, out_len);
    out_len
}

/// Try to decrypt a Sapling note using the spending key directly
/// This uses the full zcash_primitives derivation to ensure correctness
/// A simple struct implementing ShieldedOutput for note decryption
struct RawShieldedOutput {
    epk: [u8; 32],
    cmu: [u8; 32],
    enc_ciphertext: [u8; 580],
}

impl<P: Parameters> ShieldedOutput<SaplingDomain<P>, ENC_CIPHERTEXT_SIZE> for RawShieldedOutput {
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

#[no_mangle]
pub unsafe extern "C" fn zipherx_try_decrypt_note_with_sk(
    sk: *const u8,
    epk: *const u8,
    cmu: *const u8,
    ciphertext: *const u8,
    output: *mut u8,
) -> usize {
    let sk_slice = slice::from_raw_parts(sk, 169);
    let epk_slice = slice::from_raw_parts(epk, 32);
    let cmu_slice = slice::from_raw_parts(cmu, 32);
    let ciphertext_slice = slice::from_raw_parts(ciphertext, 580);

    // Deserialize the ExtendedSpendingKey
    let extsk = match ExtendedSpendingKey::read(&mut &sk_slice[..]) {
        Ok(key) => key,
        Err(e) => {
            debug_log!("DEBUG: ❌ Failed to deserialize ExtendedSpendingKey: {:?}", e);
            return 0;
        }
    };

    // Debug: print SK first bytes
    debug_log!("DEBUG: SK bytes[0..8] = {:02x?}", &sk_slice[0..8]);

    // Derive IVK using zcash_primitives
    let fvk = FullViewingKey::from_expanded_spending_key(&extsk.expsk);
    let ivk = fvk.vk.ivk();
    let prepared_ivk = PreparedIncomingViewingKey::new(&ivk);

    // Debug: print ak to verify FVK
    debug_log!("DEBUG: ak[0..4] = {:02x?}", &fvk.vk.ak.to_bytes()[0..4]);

    // Debug: derive default address and print its diversifier
    let (_, default_addr) = extsk.default_address();
    let div_bytes = default_addr.diversifier().0;
    debug_log!("DEBUG: IVK scalar = {:?}", ivk.0.to_repr());
    debug_log!("DEBUG: Default diversifier = {:02x?}", div_bytes);

    // Debug: print the full address bytes and pk_d to verify
    let addr_bytes = default_addr.to_bytes();
    debug_log!("DEBUG: Full address bytes[0..8] = {:02x?}", &addr_bytes[0..8]);
    // Use GroupEncoding trait to get bytes
    let pk_d_bytes = default_addr.pk_d().inner().to_bytes();
    debug_log!("DEBUG: pk_d bytes = {:02x?}", pk_d_bytes);

    // Verify IVK by manually computing [ivk] g_d and comparing to pk_d
    if let Some(g_d) = default_addr.diversifier().g_d() {
        let computed_pk_d = g_d * ivk.0;
        let computed_pk_d_bytes = computed_pk_d.to_bytes();
        if computed_pk_d_bytes == pk_d_bytes {
            debug_log!("DEBUG: ✅ IVK verification: [ivk] g_d == pk_d");
        } else {
            debug_log!("DEBUG: ❌ IVK verification FAILED!");
            debug_log!("DEBUG: Expected pk_d = {:02x?}", pk_d_bytes);
            debug_log!("DEBUG: Computed pk_d = {:02x?}", computed_pk_d_bytes);
        }
    }

    // Create the output struct
    let mut epk_bytes = [0u8; 32];
    let mut cmu_bytes = [0u8; 32];
    let mut enc_bytes = [0u8; 580];
    epk_bytes.copy_from_slice(epk_slice);
    cmu_bytes.copy_from_slice(cmu_slice);
    enc_bytes.copy_from_slice(ciphertext_slice);

    // Debug: print first bytes of each input
    debug_log!("DEBUG: EPK[0..4] = {:02x?}", &epk_bytes[0..4]);
    debug_log!("DEBUG: CMU[0..4] = {:02x?}", &cmu_bytes[0..4]);
    debug_log!("DEBUG: ENC[0..4] = {:02x?}", &enc_bytes[0..4]);
    debug_log!("DEBUG: About to parse EPK as curve point...");

    // Debug: try to parse EPK as a curve point
    let epk_point_opt = jubjub::ExtendedPoint::from_bytes(&epk_bytes);
    debug_log!("DEBUG: EPK parsing complete");
    let epk_valid: bool = epk_point_opt.is_some().into();
    if epk_valid {
        debug_log!("DEBUG: ✅ EPK is valid curve point");
    } else {
        debug_log!("DEBUG: ❌ EPK is NOT a valid curve point!");
        return 0;
    }
    let epk_point = epk_point_opt.unwrap();

    // Manual KDF to debug decryption
    // Clear cofactor on EPK first, then multiply by IVK (matches working test)
    let epk_cleared = epk_point.clear_cofactor();
    let ka = jubjub::ExtendedPoint::from(epk_cleared) * ivk.0;
    let ka_bytes = ka.to_affine().to_bytes();
    debug_log!("DEBUG: KA (shared secret) first 4 bytes: {:02x?}", &ka_bytes[0..4]);

    // Also print full EPK and IVK for verification
    debug_log!("DEBUG: Full EPK = {:02x?}", epk_bytes);
    debug_log!("DEBUG: Full IVK = {:02x?}", ivk.0.to_repr());

    // KDF: derive symmetric key using BLAKE2b
    let mut kdf_input = [0u8; 64];
    kdf_input[0..32].copy_from_slice(&ka_bytes);
    kdf_input[32..64].copy_from_slice(&epk_bytes);

    let key = blake2b_simd::Params::new()
        .hash_length(32)
        .personal(b"Zcash_SaplingKDF")
        .to_state()
        .update(&kdf_input)
        .finalize();

    debug_log!("DEBUG: KDF key first 4 bytes: {:02x?}", &key.as_bytes()[0..4]);

    // Try ChaCha20Poly1305 decryption
    let cipher_key = GenericArray::from_slice(key.as_bytes());
    let cipher = ChaCha20Poly1305::new(cipher_key);
    let nonce = GenericArray::from_slice(&[0u8; 12]);

    // The enc_ciphertext is 580 bytes = 564 plaintext + 16 tag
    match cipher.decrypt(nonce, &enc_bytes[..]) {
        Ok(plaintext) => {
            debug_log!("DEBUG: ✅ Manual decryption succeeded! Plaintext len: {}", plaintext.len());
            debug_log!("DEBUG: Plaintext version byte: 0x{:02x}", plaintext[0]);
            debug_log!("DEBUG: Plaintext diversifier: {:02x?}", &plaintext[1..12]);

            // Check version byte
            if plaintext[0] != 0x01 && plaintext[0] != 0x02 {
                debug_log!("DEBUG: ❌ Invalid version byte!");
            }

            // Extract value (bytes 12-20, little-endian u64)
            let value = u64::from_le_bytes(plaintext[12..20].try_into().unwrap());
            debug_log!("DEBUG: Decrypted value: {} zatoshis ({} ZCL)", value, value as f64 / 100_000_000.0);

            // Check if diversifier matches our address
            let our_div = default_addr.diversifier().0;
            if plaintext[1..12] == our_div {
                debug_log!("DEBUG: ✅ Diversifier MATCHES! This note is for us!");
            } else {
                debug_log!("DEBUG: ❌ Diversifier does not match. Note is for someone else.");
                debug_log!("DEBUG: Expected: {:02x?}", our_div);
                debug_log!("DEBUG: Got:      {:02x?}", &plaintext[1..12]);
            }
        }
        Err(_e) => {
            debug_log!("DEBUG: ❌ ChaCha20Poly1305 auth tag verification failed");
        }
    }

    let shielded_output = RawShieldedOutput {
        epk: epk_bytes,
        cmu: cmu_bytes,
        enc_ciphertext: enc_bytes,
    };

    // Use block height for the transaction (Zclassic Sapling blocks)
    let height = BlockHeight::from_u32(2918700);

    // Try to decrypt using zcash_primitives
    debug_log!("DEBUG: Now trying zcash_primitives decryption...");

    match try_sapling_note_decryption(&ZclassicNetwork, height, &prepared_ivk, &shielded_output) {
        Some((note, address, memo)) => {
            debug_log!("✅ DECRYPTION SUCCESS! Value: {} zatoshis", note.value().inner());
            // Successfully decrypted! Pack the result
            // Format: diversifier(11) + value(8) + rcm(32) + memo(512)
            let diversifier = address.diversifier().0;
            debug_log!("DEBUG: Returned diversifier from zcash_primitives: {:02x?}", diversifier);
            let value: u64 = note.value().inner();
            let rcm = match note.rseed() {
                Rseed::BeforeZip212(rcm) => rcm.to_repr(),
                Rseed::AfterZip212(rseed) => {
                    // For ZIP-212, we need to derive rcm from rseed
                    // For now, just return the rseed bytes
                    *rseed
                }
            };

            // Copy to output buffer
            let out_slice = slice::from_raw_parts_mut(output, 564);
            out_slice[0..11].copy_from_slice(&diversifier);
            out_slice[11..19].copy_from_slice(&value.to_le_bytes());
            out_slice[19..51].copy_from_slice(&rcm);
            out_slice[51..563].copy_from_slice(memo.as_array());

            564
        }
        None => 0,
    }
}

// =============================================================================
// Utility Functions
// =============================================================================

/// Get the library version
#[no_mangle]
pub extern "C" fn zipherx_version() -> u32 {
    3 // Version 3 with ZclassicButtercup branch ID support (0x930b540d)
}

/// Get the consensus branch ID for a given height on Zclassic
/// This is useful for debugging to verify the correct branch ID is being used
/// @param height Block height
/// @return Branch ID as u32 (e.g., 0x930b540d for Buttercup)
#[no_mangle]
pub extern "C" fn zipherx_get_branch_id(height: u64) -> u32 {
    let block_height = BlockHeight::from_u32(height as u32);
    let branch_id = zcash_primitives::consensus::BranchId::for_height(&ZclassicNetwork, block_height);
    let branch_id_u32: u32 = branch_id.into();

    debug_log!("🔍 zipherx_get_branch_id({}) = 0x{:08x} ({:?})", height, branch_id_u32, branch_id);

    branch_id_u32
}

/// Verify the library is using the correct ZclassicButtercup fork
/// @return true if using local fork with Buttercup support
#[no_mangle]
pub extern "C" fn zipherx_verify_buttercup_support() -> bool {
    // Test at height 2,923,000 (current chain)
    let test_height = BlockHeight::from_u32(2_923_000);
    let branch_id = zcash_primitives::consensus::BranchId::for_height(&ZclassicNetwork, test_height);
    let branch_id_u32: u32 = branch_id.into();

    let has_buttercup = branch_id_u32 == 0x930b540d;

    debug_log!("🔐 BUTTERCUP VERIFICATION:");
    debug_log!("   Test height: 2,923,000");
    debug_log!("   Branch ID: 0x{:08x}", branch_id_u32);
    debug_log!("   Expected: 0x930b540d (ZclassicButtercup)");
    debug_log!("   Match: {}", if has_buttercup { "✅ YES" } else { "❌ NO" });

    if has_buttercup {
        debug_log!("   ✅ Library correctly uses local zcash_primitives fork with Buttercup!");
    } else {
        debug_log!("   ❌ ERROR: Library NOT using local fork! Got {:?} instead of ZclassicButtercup", branch_id);
    }

    has_buttercup
}

/// Double SHA256 hash
#[no_mangle]
pub unsafe extern "C" fn zipherx_double_sha256(
    data: *const u8,
    len: usize,
    output: *mut u8,
) -> bool {
    use sha2::{Sha256, Digest};

    let input = slice::from_raw_parts(data, len);

    let hash1 = Sha256::digest(input);
    let hash2 = Sha256::digest(&hash1);

    std::ptr::copy_nonoverlapping(hash2.as_ptr(), output, 32);
    true
}

/// Free a buffer allocated by this library
#[no_mangle]
pub unsafe extern "C" fn zipherx_free(ptr: *mut u8, len: usize) {
    if !ptr.is_null() && len > 0 {
        let _ = Vec::from_raw_parts(ptr, len, len);
    }
}

// =============================================================================
// Spending Key Encoding/Decoding (Bech32)
// =============================================================================

/// Encode spending key as Bech32 string (secret-extended-key-main1...)
/// Returns length of encoded string, or 0 on failure
#[no_mangle]
pub unsafe extern "C" fn zipherx_encode_spending_key(
    sk: *const u8,
    output: *mut u8,
) -> usize {
    if sk.is_null() || output.is_null() {
        return 0;
    }

    let sk_slice = slice::from_raw_parts(sk, 169);

    // Parse the ExtendedSpendingKey
    let extsk = match ExtendedSpendingKey::read(&sk_slice[..]) {
        Ok(key) => key,
        Err(_) => return 0,
    };

    // Encode as Bech32 with the Zclassic HRP
    let hrp = ZclassicNetwork.hrp_sapling_extended_spending_key();

    // Get the raw bytes to encode
    let mut sk_bytes = Vec::new();
    if extsk.write(&mut sk_bytes).is_err() {
        return 0;
    }

    // Encode using Bech32
    let encoded = match bech32::encode(hrp, sk_bytes.to_base32(), Variant::Bech32) {
        Ok(s) => s,
        Err(_) => return 0,
    };

    let encoded_bytes = encoded.as_bytes();
    std::ptr::copy_nonoverlapping(encoded_bytes.as_ptr(), output, encoded_bytes.len());
    encoded_bytes.len()
}

/// Decode Bech32 spending key string to bytes
/// Returns true on success
#[no_mangle]
pub unsafe extern "C" fn zipherx_decode_spending_key(
    encoded: *const i8,
    output: *mut u8,
) -> bool {
    if encoded.is_null() || output.is_null() {
        return false;
    }

    let encoded_str = match std::ffi::CStr::from_ptr(encoded).to_str() {
        Ok(s) => s,
        Err(_) => return false,
    };

    // Decode Bech32
    let (hrp, data, _variant) = match bech32::decode(encoded_str) {
        Ok(result) => result,
        Err(_) => return false,
    };

    // Verify HRP matches Zclassic
    let expected_hrp = ZclassicNetwork.hrp_sapling_extended_spending_key();
    if hrp != expected_hrp {
        eprintln!("❌ Invalid HRP: expected {}, got {}", expected_hrp, hrp);
        return false;
    }

    // Convert from base32
    let sk_bytes = match Vec::<u8>::from_base32(&data) {
        Ok(bytes) => bytes,
        Err(_) => return false,
    };

    // Verify we can parse it as an ExtendedSpendingKey
    if ExtendedSpendingKey::read(&sk_bytes[..]).is_err() {
        return false;
    }

    // Copy to output
    if sk_bytes.len() != 169 {
        return false;
    }
    std::ptr::copy_nonoverlapping(sk_bytes.as_ptr(), output, 169);
    true
}

// =============================================================================
// Transaction Building - Sapling Proofs
// =============================================================================

/// Initialize the prover with Sapling parameters
/// Must be called before building transactions
/// spend_path and output_path are paths to sapling-spend.params and sapling-output.params
#[no_mangle]
pub unsafe extern "C" fn zipherx_init_prover(
    spend_path: *const i8,
    output_path: *const i8,
) -> bool {
    let spend = match std::ffi::CStr::from_ptr(spend_path).to_str() {
        Ok(s) => s,
        Err(_) => return false,
    };

    let output = match std::ffi::CStr::from_ptr(output_path).to_str() {
        Ok(s) => s,
        Err(_) => return false,
    };

    // Load the prover with Sapling parameters
    let prover = LocalTxProver::new(Path::new(spend), Path::new(output));
    let mut global_prover = PROVER.lock().unwrap();
    *global_prover = Some(prover);
    debug_log!("✅ Prover initialized with Sapling parameters");
    true
}

/// Build a complete shielded transaction
/// Returns the raw transaction bytes or 0 on failure
///
/// Parameters:
/// - sk: Extended spending key (169 bytes)
/// - to_address: Destination z-address bytes (43 bytes)
/// - amount: Amount in zatoshis
/// - memo: Optional memo (512 bytes, can be all zeros)
/// - anchor: Merkle tree anchor (32 bytes)
/// - witness_data: Serialized witness for the note being spent
/// - witness_len: Length of witness data
/// - note_value: Value of the note being spent
/// - note_rcm: Note randomness (32 bytes)
/// - note_diversifier: Note diversifier (11 bytes)
/// - tx_out: Output buffer for transaction (should be at least 10000 bytes)
#[no_mangle]
pub unsafe extern "C" fn zipherx_build_transaction(
    sk: *const u8,
    to_address: *const u8,
    amount: u64,
    memo: *const u8,
    _anchor: *const u8,
    witness_data: *const u8,
    witness_len: usize,
    note_value: u64,
    note_rcm: *const u8,
    note_diversifier: *const u8,
    chain_height: u64,
    tx_out: *mut u8,
    tx_out_len: *mut usize,
) -> bool {
    // Get the prover
    let prover_guard = PROVER.lock().unwrap();
    let prover = match prover_guard.as_ref() {
        Some(p) => p,
        None => {
            eprintln!("❌ Prover not initialized");
            return false;
        }
    };

    // Parse inputs
    let sk_slice = slice::from_raw_parts(sk, 169);
    let to_addr_slice = slice::from_raw_parts(to_address, 43);
    let witness_slice = slice::from_raw_parts(witness_data, witness_len);
    let rcm_slice = slice::from_raw_parts(note_rcm, 32);
    let div_slice = slice::from_raw_parts(note_diversifier, 11);

    // Deserialize spending key
    let extsk = match ExtendedSpendingKey::read(&mut &sk_slice[..]) {
        Ok(key) => key,
        Err(e) => {
            eprintln!("❌ Failed to read spending key: {:?}", e);
            return false;
        }
    };

    // Parse destination address
    let to_addr = match PaymentAddress::from_bytes(to_addr_slice.try_into().unwrap()) {
        Some(addr) => addr,
        None => {
            eprintln!("❌ Invalid destination address");
            return false;
        }
    };

    // Parse note commitment randomness
    let mut rcm_bytes = [0u8; 32];
    rcm_bytes.copy_from_slice(rcm_slice);
    let rcm = match Option::<jubjub::Fr>::from(jubjub::Fr::from_repr(rcm_bytes)) {
        Some(r) => r,
        None => {
            eprintln!("❌ Invalid rcm");
            return false;
        }
    };

    // Parse diversifier
    let mut div_bytes = [0u8; 11];
    div_bytes.copy_from_slice(div_slice);
    let diversifier = Diversifier(div_bytes);
    debug_log!("DEBUG: Received diversifier for spending: {:02x?}", div_bytes);

    // Get the address that received this note using the note's diversifier
    let fvk = extsk.to_diversifiable_full_viewing_key();
    let note_addr = match fvk.fvk().vk.to_payment_address(diversifier) {
        Some(addr) => addr,
        None => {
            eprintln!("❌ Invalid diversifier for note address");
            debug_log!("DEBUG: Expected valid diversifier like [c7, 99, e1, e4, 37, 90, fa, a5, 04, bd, df]");
            return false;
        }
    };

    // Calculate fee
    let fee = 10000u64;

    // Verify funds
    if note_value < amount + fee {
        eprintln!("❌ Insufficient funds: have {}, need {}", note_value, amount + fee);
        return false;
    }

    // Create note to spend using the diversifier's address
    let note = zcash_primitives::sapling::Note::from_parts(
        note_addr,
        NoteValue::from_raw(note_value),
        Rseed::BeforeZip212(rcm),
    );

    // Compute note CMU for verification
    let computed_cmu = note.cmu();
    let cmu_bytes: [u8; 32] = computed_cmu.to_bytes();
    debug_log!("🔍 Computed note CMU: {}", hex::encode(&cmu_bytes));

    // Deserialize the IncrementalWitness from standard format
    let mut reader = std::io::Cursor::new(witness_slice);
    let witness: IncrementalWitness<zcash_primitives::sapling::Node, 32> =
        match zcash_primitives::merkle_tree::read_incremental_witness(&mut reader) {
            Ok(w) => w,
            Err(e) => {
                eprintln!("❌ Failed to deserialize witness: {:?}", e);
                return false;
            }
        };

    // Get the merkle path from the witness
    let merkle_path = match witness.path() {
        Some(p) => p,
        None => {
            eprintln!("❌ Failed to get merkle path from witness");
            return false;
        }
    };

    let position = u64::from(witness.tip_position()) as u32;
    debug_log!("🔍 Witness position: {}", position);

    // Create transaction builder
    // Use current chain height for proper expiry calculation
    let target_height = BlockHeight::from_u32(chain_height as u32);
    let mut builder = Builder::new(ZclassicNetwork, target_height, None);

    // Verify branch ID (only log errors for wrong branch ID)
    let branch_id = zcash_primitives::consensus::BranchId::for_height(&ZclassicNetwork, target_height);
    let branch_id_u32: u32 = branch_id.into();
    debug_log!("🔑 Branch ID: 0x{:08x} at height {}", branch_id_u32, chain_height);

    // Only warn if branch ID is wrong for current height
    if chain_height >= 707000 && branch_id_u32 != 0x930b540d {
        eprintln!("❌ ERROR: At height {}, expected branch ID 0x930b540d (Buttercup) but got 0x{:08x}", chain_height, branch_id_u32);
    }

    // Add spend
    if let Err(e) = builder.add_sapling_spend(
        extsk.clone(),
        diversifier,
        note.clone(),
        merkle_path,
    ) {
        eprintln!("❌ Failed to add spend: {:?}", e);
        return false;
    }
    debug_log!("✅ Spend added successfully");

    // Prepare memo
    let memo_bytes = if memo.is_null() {
        [0u8; 512]
    } else {
        let memo_slice = slice::from_raw_parts(memo, 512);
        let mut m = [0u8; 512];
        m.copy_from_slice(memo_slice);
        m
    };
    let memo_obj = MemoBytes::from_bytes(&memo_bytes).unwrap();

    // Convert amount to Amount type
    let amount_val = Amount::from_i64(amount as i64).unwrap();

    // Add output to recipient
    if let Err(e) = builder.add_sapling_output(
        Some(extsk.expsk.ovk),
        to_addr,
        amount_val,
        memo_obj,
    ) {
        eprintln!("❌ Failed to add output: {:?}", e);
        return false;
    }

    // Add change output if needed
    let change = note_value - amount - fee;
    if change > 0 {
        let change_memo = MemoBytes::empty();
        let change_amount = Amount::from_i64(change as i64).unwrap();
        // Send change back to sender's default address
        let (_, change_addr) = extsk.default_address();
        if let Err(e) = builder.add_sapling_output(
            Some(extsk.expsk.ovk),
            change_addr,
            change_amount,
            change_memo,
        ) {
            eprintln!("❌ Failed to add change output: {:?}", e);
            return false;
        }
    }

    // Build the transaction with proofs
    debug_log!("🔨 Building transaction...");
    let (tx, _) = match builder.build(prover, &zcash_primitives::transaction::fees::fixed::FeeRule::non_standard(Amount::from_i64(fee as i64).unwrap())) {
        Ok(result) => result,
        Err(e) => {
            eprintln!("❌ Failed to build transaction: {:?}", e);
            return false;
        }
    };

    // Serialize transaction
    let mut tx_bytes = Vec::new();
    if let Err(e) = tx.write(&mut tx_bytes) {
        eprintln!("❌ Failed to serialize transaction: {:?}", e);
        return false;
    }

    debug_log!("✅ Transaction built: {} bytes", tx_bytes.len());

    // Copy to output
    if tx_bytes.len() > 10000 {
        eprintln!("❌ Transaction too large: {} bytes", tx_bytes.len());
        return false;
    }

    std::ptr::copy_nonoverlapping(tx_bytes.as_ptr(), tx_out, tx_bytes.len());
    *tx_out_len = tx_bytes.len();

    true
}

/// Create a value commitment
#[no_mangle]
pub unsafe extern "C" fn zipherx_compute_value_commitment(
    value: u64,
    rcv: *const u8,
    cv_out: *mut u8,
) -> bool {
    let rcv_slice = slice::from_raw_parts(rcv, 32);

    let mut rcv_bytes = [0u8; 32];
    rcv_bytes.copy_from_slice(rcv_slice);

    let _rcv_scalar = match Option::<jubjub::Fr>::from(jubjub::Fr::from_repr(rcv_bytes)) {
        Some(r) => r,
        None => return false,
    };

    // Compute value commitment using the random trapdoor
    let trapdoor = zcash_primitives::sapling::value::ValueCommitTrapdoor::random(&mut OsRng);
    let cv = zcash_primitives::sapling::value::ValueCommitment::derive(NoteValue::from_raw(value), trapdoor);
    let cv_bytes = cv.to_bytes();

    std::ptr::copy_nonoverlapping(cv_bytes.as_ptr(), cv_out, 32);
    true
}

/// Generate a random scalar for value commitment
#[no_mangle]
pub unsafe extern "C" fn zipherx_random_scalar(output: *mut u8) -> bool {
    let scalar = jubjub::Fr::random(&mut OsRng);
    let bytes = scalar.to_repr();
    std::ptr::copy_nonoverlapping(bytes.as_ptr(), output, 32);
    true
}

/// Encrypt note plaintext for Sapling output
#[no_mangle]
pub unsafe extern "C" fn zipherx_encrypt_note(
    diversifier: *const u8,
    pk_d: *const u8,
    value: u64,
    rcm: *const u8,
    memo: *const u8,
    epk_out: *mut u8,
    enc_out: *mut u8,
) -> bool {
    use chacha20poly1305::{ChaCha20Poly1305, Key, Nonce, aead::Aead, KeyInit};

    let div_slice = slice::from_raw_parts(diversifier, 11);
    let pk_d_slice = slice::from_raw_parts(pk_d, 32);
    let rcm_slice = slice::from_raw_parts(rcm, 32);
    let memo_slice = slice::from_raw_parts(memo, 512);

    // Generate ephemeral secret key
    let esk = jubjub::Fr::random(&mut OsRng);

    // Parse pk_d as a point
    let mut pk_d_bytes = [0u8; 32];
    pk_d_bytes.copy_from_slice(pk_d_slice);
    let pk_d_point: jubjub::ExtendedPoint = match Option::<jubjub::ExtendedPoint>::from(
        jubjub::ExtendedPoint::from_bytes(&pk_d_bytes)
    ) {
        Some(p) => p,
        None => return false,
    };

    // Compute ephemeral public key: epk = esk * pk_d
    let epk = pk_d_point * esk;
    let epk_bytes = epk.to_bytes();
    std::ptr::copy_nonoverlapping(epk_bytes.as_ptr(), epk_out, 32);

    // Compute shared secret
    let shared_secret = pk_d_point * esk;
    let shared_bytes = shared_secret.to_bytes();

    // KDF
    let mut kdf_hasher = blake2b_simd::Params::new()
        .hash_length(32)
        .personal(b"Zcash_SaplingKDF")
        .to_state();
    kdf_hasher.update(&shared_bytes);
    kdf_hasher.update(&epk_bytes);
    let symmetric_key = kdf_hasher.finalize();

    // Build plaintext: diversifier (11) + value (8) + rcm (32) + memo (512) = 563 bytes
    let mut plaintext = Vec::with_capacity(564);
    plaintext.extend_from_slice(div_slice);
    plaintext.extend_from_slice(&value.to_le_bytes());
    plaintext.extend_from_slice(rcm_slice);
    plaintext.extend_from_slice(memo_slice);

    // Pad to 564 bytes
    while plaintext.len() < 564 {
        plaintext.push(0);
    }

    // Encrypt with ChaCha20Poly1305
    let key = Key::from_slice(symmetric_key.as_bytes());
    let cipher = ChaCha20Poly1305::new(key);
    let nonce = Nonce::from_slice(&[0u8; 12]);

    let ciphertext = match cipher.encrypt(nonce, plaintext.as_slice()) {
        Ok(c) => c,
        Err(_) => return false,
    };

    // Output is 564 + 16 = 580 bytes
    std::ptr::copy_nonoverlapping(ciphertext.as_ptr(), enc_out, 580);

    true
}

// =============================================================================
// Sapling Commitment Tree - For generating witnesses
// =============================================================================

// We need to track witnesses separately since the tree doesn't support random access
// Global tree and witness storage
static COMMITMENT_TREE: Mutex<Option<CommitmentTree<zcash_primitives::sapling::Node, 32>>> = Mutex::new(None);
static WITNESSES: Mutex<Vec<IncrementalWitness<zcash_primitives::sapling::Node, 32>>> = Mutex::new(Vec::new());
static TREE_POSITION: Mutex<u64> = Mutex::new(0);

/// Initialize a new empty Sapling commitment tree
#[no_mangle]
pub extern "C" fn zipherx_tree_init() -> bool {
    let mut tree_guard = COMMITMENT_TREE.lock().unwrap();
    *tree_guard = Some(CommitmentTree::empty());

    let mut witnesses_guard = WITNESSES.lock().unwrap();
    witnesses_guard.clear();

    let mut pos_guard = TREE_POSITION.lock().unwrap();
    *pos_guard = 0;

    true
}

/// Add a note commitment (cmu) to the tree
/// cmu: 32-byte note commitment in WIRE FORMAT (little-endian)
/// Returns the position of the added commitment
#[no_mangle]
pub unsafe extern "C" fn zipherx_tree_append(cmu: *const u8) -> u64 {
    let cmu_slice = slice::from_raw_parts(cmu, 32);

    let mut tree_guard = COMMITMENT_TREE.lock().unwrap();
    let tree = match tree_guard.as_mut() {
        Some(t) => t,
        None => return u64::MAX, // Tree not initialized
    };

    // Parse cmu as a Sapling Node using Node::read()
    // IMPORTANT: CMU must be in wire format (little-endian), same as treeLoadFromCMUs
    // This ensures consistency - both functions parse CMUs the same way
    let node = match zcash_primitives::sapling::Node::read(cmu_slice) {
        Ok(n) => n,
        Err(_) => return u64::MAX,
    };

    // Append to tree
    if tree.append(node).is_err() {
        return u64::MAX;
    }

    // Update all existing witnesses with this new node
    let mut witnesses_guard = WITNESSES.lock().unwrap();
    for witness in witnesses_guard.iter_mut() {
        witness.append(node).ok();
    }

    let mut pos_guard = TREE_POSITION.lock().unwrap();
    let position = *pos_guard;
    *pos_guard += 1;

    position
}

/// Create a witness for the current position in the tree
/// Call this right after appending a note that belongs to us
/// Returns the witness index (to retrieve later) or u64::MAX on error
#[no_mangle]
pub extern "C" fn zipherx_tree_witness_current() -> u64 {
    let tree_guard = COMMITMENT_TREE.lock().unwrap();
    let tree = match tree_guard.as_ref() {
        Some(t) => t.clone(),
        None => return u64::MAX,
    };

    let witness = IncrementalWitness::from_tree(tree);

    let mut witnesses_guard = WITNESSES.lock().unwrap();
    let index = witnesses_guard.len();
    witnesses_guard.push(witness);

    index as u64
}

/// Load a witness from serialized data into the WITNESSES array
/// This allows us to track and update previously saved witnesses
/// Returns the witness index or u64::MAX on error
#[no_mangle]
pub unsafe extern "C" fn zipherx_tree_load_witness(
    witness_data: *const u8,
    witness_len: usize,
) -> u64 {
    if witness_len < 1028 {
        debug_log!("❌ Witness data too short: {} bytes", witness_len);
        return u64::MAX;
    }

    let witness_slice = slice::from_raw_parts(witness_data, witness_len);

    // Deserialize the IncrementalWitness directly
    // Format: serialized IncrementalWitness (variable length)
    let mut reader = std::io::Cursor::new(witness_slice);

    let witness = match zcash_primitives::merkle_tree::read_incremental_witness(&mut reader) {
        Ok(w) => w,
        Err(e) => {
            debug_log!("❌ Failed to deserialize witness: {:?}", e);
            return u64::MAX;
        }
    };

    let mut witnesses_guard = WITNESSES.lock().unwrap();
    let index = witnesses_guard.len();
    witnesses_guard.push(witness);

    debug_log!("📝 Loaded witness at index {}", index);
    index as u64
}

/// Get the root of the tree
/// root_out: 32-byte output buffer for the root
#[no_mangle]
pub unsafe extern "C" fn zipherx_tree_root(root_out: *mut u8) -> bool {
    let tree_guard = COMMITMENT_TREE.lock().unwrap();
    let tree = match tree_guard.as_ref() {
        Some(t) => t,
        None => return false,
    };

    let root = tree.root();
    let mut root_bytes = Vec::new();
    root.write(&mut root_bytes).unwrap();

    std::ptr::copy_nonoverlapping(root_bytes.as_ptr(), root_out, 32);
    true
}

/// Update a witness with a new CMU
/// This is used to keep witnesses current as new notes are added
/// witness_data: Current witness data (1028 bytes)
/// cmu: New commitment to append (32 bytes)
/// witness_out: Output buffer for updated witness (1028 bytes)
/// Returns true if successful
#[no_mangle]
pub unsafe extern "C" fn zipherx_witness_update(
    witness_data: *const u8,
    witness_len: usize,
    cmu: *const u8,
    witness_out: *mut u8,
) -> bool {
    if witness_len < 1028 {
        return false;
    }

    let witness_slice = slice::from_raw_parts(witness_data, witness_len);
    let cmu_slice = slice::from_raw_parts(cmu, 32);

    // Parse position from witness
    let position = u32::from_le_bytes(witness_slice[0..4].try_into().unwrap());

    // Parse CMU as node
    let mut cmu_bytes = [0u8; 32];
    cmu_bytes.copy_from_slice(cmu_slice);
    let node = match bls12_381::Scalar::from_repr(cmu_bytes).into() {
        Some(scalar) => zcash_primitives::sapling::Node::from_scalar(scalar),
        None => return false,
    };

    // Parse merkle path from witness
    let mut path_hashes = Vec::with_capacity(32);
    for i in 0..32 {
        let start = 4 + i * 32;
        let mut hash = [0u8; 32];
        hash.copy_from_slice(&witness_slice[start..start+32]);
        let scalar = match bls12_381::Scalar::from_repr(hash).into() {
            Some(s) => s,
            None => return false,
        };
        path_hashes.push(zcash_primitives::sapling::Node::from_scalar(scalar));
    }

    // Create incremental witness from path
    // Note: This is a simplified update - for a full implementation we'd need
    // to properly reconstruct the IncrementalWitness and call append()
    // For now, we'll update the path based on the new leaf position

    // The witness needs the IncrementalWitness::append method which requires
    // the full witness state. Since we only have the path, we can't easily update.
    //
    // The proper solution is to keep witnesses in memory and update them during scan.
    // For now, return false to indicate this needs the full witness updating approach.

    false
}

/// Get witness data for a specific witness index
/// witness_index: Index returned by zipherx_tree_witness_current
/// witness_out: Output buffer for witness (1028 bytes: 4 bytes position + 32*32 bytes path)
/// Returns true if successful
#[no_mangle]
pub unsafe extern "C" fn zipherx_tree_get_witness(
    witness_index: u64,
    witness_out: *mut u8,
) -> bool {
    let witnesses_guard = WITNESSES.lock().unwrap();
    let witness = match witnesses_guard.get(witness_index as usize) {
        Some(w) => w,
        None => {
            debug_log!("❌ Invalid witness index {}", witness_index);
            return false;
        }
    };

    // Debug: Print the root that this witness produces
    let witness_root = witness.root();
    let mut witness_root_bytes = [0u8; 32];
    witness_root.write(&mut witness_root_bytes[..]).unwrap();
    debug_log!("🔍 Witness root (wire format): {}", hex::encode(&witness_root_bytes));

    // Serialize the IncrementalWitness using zcash standard format
    let mut serialized = Vec::new();
    if zcash_primitives::merkle_tree::write_incremental_witness(witness, &mut serialized).is_err() {
        debug_log!("❌ Failed to serialize witness");
        return false;
    }

    // Copy to output buffer (must be at least 1028 bytes)
    if serialized.len() > 1028 {
        debug_log!("❌ Serialized witness too large: {} bytes", serialized.len());
        return false;
    }

    std::ptr::copy_nonoverlapping(serialized.as_ptr(), witness_out, serialized.len());
    // Zero-pad remaining bytes
    if serialized.len() < 1028 {
        std::ptr::write_bytes(witness_out.add(serialized.len()), 0, 1028 - serialized.len());
    }

    debug_log!("📝 Serialized witness: {} bytes", serialized.len());
    true
}

/// Get current tree size (number of commitments)
#[no_mangle]
pub extern "C" fn zipherx_tree_size() -> u64 {
    let pos_guard = TREE_POSITION.lock().unwrap();
    *pos_guard
}

/// Serialize tree state for persistence
/// tree_out: Output buffer (should be large, e.g., 100KB)
/// tree_out_len: Output length
/// Returns true if successful
#[no_mangle]
pub unsafe extern "C" fn zipherx_tree_serialize(
    tree_out: *mut u8,
    tree_out_len: *mut usize,
) -> bool {
    let tree_guard = COMMITMENT_TREE.lock().unwrap();
    let tree = match tree_guard.as_ref() {
        Some(t) => t,
        None => return false,
    };

    let mut data = Vec::new();

    // Write tree size first
    let pos_guard = TREE_POSITION.lock().unwrap();
    data.extend_from_slice(&pos_guard.to_le_bytes());

    // Serialize tree
    if write_commitment_tree(tree, &mut data).is_err() {
        return false;
    }

    if data.len() > 100_000 {
        debug_log!("❌ Tree too large to serialize");
        return false;
    }

    std::ptr::copy_nonoverlapping(data.as_ptr(), tree_out, data.len());
    *tree_out_len = data.len();

    true
}

/// Deserialize tree state from persistence
/// tree_data: Serialized tree data
/// tree_len: Length of data
/// Returns true if successful
#[no_mangle]
pub unsafe extern "C" fn zipherx_tree_deserialize(
    tree_data: *const u8,
    tree_len: usize,
) -> bool {
    if tree_len < 8 {
        return false;
    }

    let data = slice::from_raw_parts(tree_data, tree_len);

    // Read position
    let position = u64::from_le_bytes(data[0..8].try_into().unwrap());

    // Deserialize tree
    let tree = match read_commitment_tree(&data[8..]) {
        Ok(t) => t,
        Err(e) => {
            eprintln!("❌ Failed to deserialize tree: {:?}", e);
            return false;
        }
    };

    let mut tree_guard = COMMITMENT_TREE.lock().unwrap();
    *tree_guard = Some(tree);

    let mut pos_guard = TREE_POSITION.lock().unwrap();
    *pos_guard = position;

    true
}

/// Load tree from raw CMUs file format
/// Format: [count: u64 LE][cmu1: 32 bytes][cmu2: 32 bytes]...
/// Returns true if successful
#[no_mangle]
pub unsafe extern "C" fn zipherx_tree_load_from_cmus(
    data: *const u8,
    data_len: usize,
) -> bool {
    if data_len < 8 {
        return false;
    }

    let bytes = slice::from_raw_parts(data, data_len);

    // Read count
    let count = u64::from_le_bytes(bytes[0..8].try_into().unwrap());
    let expected_len = 8 + (count as usize * 32);

    if data_len < expected_len {
        return false;
    }

    debug_log!("📦 Loading {} CMUs into tree...", count);

    // Initialize empty tree
    let mut tree: CommitmentTree<zcash_primitives::sapling::Node, 32> = CommitmentTree::empty();

    // Append all CMUs - CMUs are stored in wire format (little-endian)
    let mut offset = 8;
    for i in 0..count {
        let cmu_bytes = &bytes[offset..offset + 32];
        offset += 32;

        let node = match zcash_primitives::sapling::Node::read(&cmu_bytes[..]) {
            Ok(n) => n,
            Err(_) => return false,
        };

        if tree.append(node).is_err() {
            return false;
        }
    }

    // Store in global
    let mut tree_guard = COMMITMENT_TREE.lock().unwrap();
    *tree_guard = Some(tree);

    let mut pos_guard = TREE_POSITION.lock().unwrap();
    *pos_guard = count;

    debug_log!("✅ Tree loaded with {} commitments", count);

    true
}

/// Progress callback type for tree loading
/// Parameters: current CMU index, total CMU count
pub type TreeLoadProgressCallback = extern "C" fn(current: u64, total: u64);

/// Load commitment tree from bundled CMU data with progress callback
/// This allows Swift to show real-time progress during tree loading
#[no_mangle]
pub unsafe extern "C" fn zipherx_tree_load_from_cmus_with_progress(
    data: *const u8,
    data_len: usize,
    progress_callback: TreeLoadProgressCallback,
) -> bool {
    if data_len < 8 {
        return false;
    }

    let bytes = slice::from_raw_parts(data, data_len);

    // Read count
    let count = u64::from_le_bytes(bytes[0..8].try_into().unwrap());
    let expected_len = 8 + (count as usize * 32);

    if data_len < expected_len {
        return false;
    }

    // Report initial progress
    progress_callback(0, count);

    // Initialize empty tree
    let mut tree: CommitmentTree<zcash_primitives::sapling::Node, 32> = CommitmentTree::empty();

    // Append all CMUs
    let mut offset = 8;
    for i in 0..count {
        let cmu_bytes = &bytes[offset..offset + 32];
        offset += 32;

        let node = match zcash_primitives::sapling::Node::read(&cmu_bytes[..]) {
            Ok(n) => n,
            Err(_) => return false,
        };

        if tree.append(node).is_err() {
            return false;
        }

        // Report progress every 10000 CMUs (about 100 updates for 1M CMUs)
        if i > 0 && i % 10000 == 0 {
            progress_callback(i, count);
        }
    }

    // Final progress
    progress_callback(count, count);

    // Store in global
    let mut tree_guard = COMMITMENT_TREE.lock().unwrap();
    *tree_guard = Some(tree);

    let mut pos_guard = TREE_POSITION.lock().unwrap();
    *pos_guard = count;

    debug_log!("✅ Tree loaded with {} commitments", count);

    true
}

/// Create a witness for a specific CMU from bundled CMU data
/// This is used for notes discovered in PHASE 1 (parallel scan) within bundled tree range
///
/// Parameters:
/// - cmu_data: Pointer to bundled CMU file data [count: u64][cmu1: 32]...
/// - cmu_data_len: Length of CMU data
/// - target_cmu: The 32-byte CMU to create witness for
/// - witness_out: Output buffer for serialized witness (at least 2000 bytes)
/// - witness_out_len: Output for actual witness length
///
/// Returns: The position (0-indexed) of the CMU, or u64::MAX on error
#[no_mangle]
pub unsafe extern "C" fn zipherx_tree_create_witness_for_cmu(
    cmu_data: *const u8,
    cmu_data_len: usize,
    target_cmu: *const u8,
    witness_out: *mut u8,
    witness_out_len: *mut usize,
) -> u64 {
    if cmu_data_len < 8 {
        return u64::MAX;
    }

    let bytes = slice::from_raw_parts(cmu_data, cmu_data_len);
    let target_bytes = slice::from_raw_parts(target_cmu, 32);

    // Read count
    let count = u64::from_le_bytes(bytes[0..8].try_into().unwrap());
    let expected_len = 8 + (count as usize * 32);

    if cmu_data_len < expected_len {
        return u64::MAX;
    }

    // Find target CMU position (compare against wire format in file)
    let mut target_pos: Option<u64> = None;
    let mut offset = 8;
    for i in 0..count {
        if &bytes[offset..offset + 32] == target_bytes {
            target_pos = Some(i);
            break;
        }
        offset += 32;
    }

    let target_pos = match target_pos {
        Some(p) => p,
        None => {
            debug_log!("❌ Target CMU not found in bundled data");
            return u64::MAX;
        }
    };

    debug_log!("📍 Found target CMU at position {}", target_pos);

    // Build tree up to target position, creating witness there
    let mut tree: CommitmentTree<zcash_primitives::sapling::Node, 32> = CommitmentTree::empty();
    let mut witness: Option<IncrementalWitness<zcash_primitives::sapling::Node, 32>> = None;

    offset = 8;
    for i in 0..count {
        let cmu_bytes = &bytes[offset..offset + 32];
        offset += 32;

        let node = match zcash_primitives::sapling::Node::read(&cmu_bytes[..]) {
            Ok(n) => n,
            Err(_) => return u64::MAX,
        };

        if tree.append(node).is_err() {
            return u64::MAX;
        }

        // Create witness at target position
        if i == target_pos {
            witness = Some(IncrementalWitness::from_tree(tree.clone()));
        } else if i > target_pos {
            // Update existing witness with new nodes
            if let Some(ref mut w) = witness {
                w.append(node).ok();
            }
        }
    }

    // Serialize witness
    let witness = match witness {
        Some(w) => w,
        None => return u64::MAX,
    };

    let mut serialized = Vec::new();
    if write_incremental_witness(&witness, &mut serialized).is_err() {
        return u64::MAX;
    }

    debug_log!("📝 Serialized witness: {} bytes", serialized.len());

    // Copy to output
    if serialized.len() > 2000 {
        return u64::MAX;
    }

    std::ptr::copy_nonoverlapping(serialized.as_ptr(), witness_out, serialized.len());
    *witness_out_len = serialized.len();

    target_pos
}

/// Find the position of a CMU in bundled CMU data (fast - no tree building)
/// Returns the 0-indexed position, or u64::MAX if not found
#[no_mangle]
pub unsafe extern "C" fn zipherx_find_cmu_position(
    cmu_data: *const u8,
    cmu_data_len: usize,
    target_cmu: *const u8,
) -> u64 {
    if cmu_data_len < 8 {
        return u64::MAX;
    }

    let bytes = slice::from_raw_parts(cmu_data, cmu_data_len);
    let target_bytes = slice::from_raw_parts(target_cmu, 32);

    // Read count
    let count = u64::from_le_bytes(bytes[0..8].try_into().unwrap());
    let expected_len = 8 + (count as usize * 32);

    if cmu_data_len < expected_len {
        return u64::MAX;
    }

    // Linear search for target CMU
    let mut offset = 8;
    for i in 0..count {
        if &bytes[offset..offset + 32] == target_bytes {
            return i;
        }
        offset += 32;
    }

    u64::MAX
}

// =============================================================================
// OVK Output Recovery (for viewing sent transactions)
// =============================================================================

/// Try to recover a sent note using the outgoing viewing key
/// This allows the sender to see what they sent
///
/// Parameters:
/// - ovk: 32-byte outgoing viewing key
/// - cv: 32-byte value commitment
/// - cmu: 32-byte note commitment
/// - epk: 32-byte ephemeral public key
/// - enc_ciphertext: 580-byte encrypted ciphertext
/// - out_ciphertext: 80-byte output ciphertext
/// - output: Buffer for result (at least 620 bytes: 11 div + 32 pk_d + 8 value + 32 rcm + 512 memo + padding)
///
/// Returns: Length of output on success, 0 on failure
#[no_mangle]
pub unsafe extern "C" fn zipherx_try_recover_output_with_ovk(
    ovk: *const u8,
    cv: *const u8,
    cmu: *const u8,
    epk: *const u8,
    enc_ciphertext: *const u8,
    out_ciphertext: *const u8,
    output: *mut u8,
) -> usize {
    use zcash_primitives::sapling::value::ValueCommitment;

    // Parse OVK
    let ovk_bytes = slice::from_raw_parts(ovk, 32);
    let ovk = OutgoingViewingKey(ovk_bytes.try_into().unwrap());

    // Parse value commitment (cv)
    let cv_bytes: [u8; 32] = slice::from_raw_parts(cv, 32).try_into().unwrap();
    let cv = match ValueCommitment::from_bytes_not_small_order(&cv_bytes).into() {
        Some(v) => v,
        None => return 0,
    };

    // Parse cmu
    let cmu_bytes: [u8; 32] = slice::from_raw_parts(cmu, 32).try_into().unwrap();
    let cmu = match zcash_primitives::sapling::note::ExtractedNoteCommitment::from_bytes(&cmu_bytes).into() {
        Some(c) => c,
        None => return 0,
    };

    // Parse EPK
    let epk_bytes: [u8; 32] = slice::from_raw_parts(epk, 32).try_into().unwrap();
    let epk = EphemeralKeyBytes(epk_bytes);

    // Get ciphertexts
    let enc = slice::from_raw_parts(enc_ciphertext, 580);
    let out = slice::from_raw_parts(out_ciphertext, 80);

    let mut enc_arr = [0u8; 580];
    enc_arr.copy_from_slice(enc);
    let mut out_arr = [0u8; 80];
    out_arr.copy_from_slice(out);

    // Create a custom output structure that implements ShieldedOutput
    struct RecoveryOutput {
        cv: ValueCommitment,
        cmu: zcash_primitives::sapling::note::ExtractedNoteCommitment,
        epk: EphemeralKeyBytes,
        enc: [u8; 580],
        out: [u8; 80],
    }

    impl ShieldedOutput<SaplingDomain<ZclassicNetwork>, 580> for RecoveryOutput {
        fn ephemeral_key(&self) -> EphemeralKeyBytes {
            self.epk.clone()
        }
        fn cmstar_bytes(&self) -> [u8; 32] {
            self.cmu.to_bytes()
        }
        fn enc_ciphertext(&self) -> &[u8; 580] {
            &self.enc
        }
    }

    // Also need to implement for output recovery which needs cv and out_ciphertext
    impl RecoveryOutput {
        fn cv(&self) -> &ValueCommitment {
            &self.cv
        }
        fn out_ciphertext(&self) -> &[u8; 80] {
            &self.out
        }
    }

    let recovery_output = RecoveryOutput {
        cv,
        cmu,
        epk,
        enc: enc_arr,
        out: out_arr,
    };

    // Use a recent height for recovery
    let height = BlockHeight::from_u32(2900000);

    // Use try_sapling_output_recovery_with_ovk which takes the components directly
    let domain = SaplingDomain::for_height(ZclassicNetwork, height);

    match zcash_note_encryption::try_output_recovery_with_ovk(
        &domain,
        &ovk,
        &recovery_output,
        recovery_output.cv(),
        recovery_output.out_ciphertext(),
    ) {
        Some((note, payment_address, memo)) => {
            // Successfully recovered! Pack the result
            let mut result = Vec::with_capacity(620);

            // Diversifier (11 bytes)
            result.extend_from_slice(&payment_address.diversifier().0);

            // pk_d (32 bytes) - use to_bytes on the underlying point
            let pk_d_bytes: [u8; 32] = payment_address.to_bytes()[11..43].try_into().unwrap();
            result.extend_from_slice(&pk_d_bytes);

            // Value (8 bytes, little-endian)
            result.extend_from_slice(&note.value().inner().to_le_bytes());

            // Rcm (32 bytes)
            let rcm_bytes = match note.rseed() {
                Rseed::BeforeZip212(rcm) => rcm.to_repr(),
                Rseed::AfterZip212(rseed) => {
                    // For AfterZip212, we store the rseed directly
                    *rseed
                }
            };
            result.extend_from_slice(&rcm_bytes);

            // Memo (512 bytes)
            result.extend_from_slice(memo.as_array());

            // Copy to output buffer
            let len = result.len();
            std::ptr::copy_nonoverlapping(result.as_ptr(), output, len);

            len
        }
        None => 0,
    }
}

/// Derive OVK from extended spending key
/// sk: 169-byte extended spending key
/// ovk_out: Buffer for 32-byte OVK
/// Returns true on success
#[no_mangle]
pub unsafe extern "C" fn zipherx_derive_ovk(
    sk: *const u8,
    ovk_out: *mut u8,
) -> bool {
    let sk_bytes = slice::from_raw_parts(sk, 169);

    // Deserialize the extended spending key
    let extsk = match ExtendedSpendingKey::read(&sk_bytes[..]) {
        Ok(key) => key,
        Err(_) => return false,
    };

    // Get the OVK from the extended spending key
    let ovk = extsk.expsk.ovk;

    // Copy to output
    std::ptr::copy_nonoverlapping(ovk.0.as_ptr(), ovk_out, 32);

    true
}

// Add debugging for anchor mismatch
