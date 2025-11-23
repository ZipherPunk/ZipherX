//! ZipherX FFI - C bindings for Sapling cryptography
//!
//! This crate provides C-compatible functions for iOS integration
//! Using real librustzcash for proper Sapling operations

use std::slice;
use std::sync::Mutex;
use std::path::Path;
use bip0039::{Count, English, Mnemonic};
use bech32::{ToBase32, FromBase32, Variant};

use zcash_primitives::{
    consensus::{Parameters, MainNetwork, BlockHeight, NetworkUpgrade},
    sapling::{
        keys::FullViewingKey,
        Diversifier, PaymentAddress,
        value::NoteValue,
        Rseed,
        note_encryption::{try_sapling_note_decryption, PreparedIncomingViewingKey, SaplingDomain},
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
use zcash_primitives::merkle_tree::{read_commitment_tree, write_commitment_tree, HashSer};
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
        // Zclassic does NOT have Canopy - this is critical for note decryption!
        match nu {
            NetworkUpgrade::Overwinter => Some(BlockHeight::from_u32(476969)),
            NetworkUpgrade::Sapling => Some(BlockHeight::from_u32(476969)),
            NetworkUpgrade::Blossom => Some(BlockHeight::from_u32(585318)), // "Bubbles"
            NetworkUpgrade::Heartwood => Some(BlockHeight::from_u32(707000)), // "Buttercup"
            NetworkUpgrade::Canopy => None, // NOT activated on Zclassic!
            NetworkUpgrade::Nu5 => None, // NOT activated
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


/// Compute nullifier for a note
#[no_mangle]
pub unsafe extern "C" fn zipherx_compute_nullifier(
    viewing_key: *const u8,
    diversifier: *const u8,
    value: u64,
    rcm: *const u8,
    position: u64,
    nf_out: *mut u8,
) -> bool {
    let vk_slice = slice::from_raw_parts(viewing_key, 32);
    let div_slice = slice::from_raw_parts(diversifier, 11);
    let rcm_slice = slice::from_raw_parts(rcm, 32);

    // Compute nullifier using BLAKE2b with Zcash personalization
    let mut hasher = blake2b_simd::Params::new()
        .hash_length(32)
        .personal(b"Zcash_nf")
        .to_state();

    hasher.update(vk_slice);
    hasher.update(div_slice);
    hasher.update(&value.to_le_bytes());
    hasher.update(rcm_slice);
    hasher.update(&position.to_le_bytes());

    let hash = hasher.finalize();
    std::ptr::copy_nonoverlapping(hash.as_bytes().as_ptr(), nf_out, 32);

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
    eprintln!("DEBUG decode_address: diversifier = {:02x?}", &bytes[0..11]);

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
            eprintln!("DEBUG: ❌ Failed to deserialize ExtendedSpendingKey: {:?}", e);
            return 0;
        }
    };

    // Debug: print SK first bytes
    eprintln!("DEBUG: SK bytes[0..8] = {:02x?}", &sk_slice[0..8]);

    // Derive IVK using zcash_primitives
    let fvk = FullViewingKey::from_expanded_spending_key(&extsk.expsk);
    let ivk = fvk.vk.ivk();
    let prepared_ivk = PreparedIncomingViewingKey::new(&ivk);

    // Debug: print ak to verify FVK
    eprintln!("DEBUG: ak[0..4] = {:02x?}", &fvk.vk.ak.to_bytes()[0..4]);

    // Debug: derive default address and print its diversifier
    let (_, default_addr) = extsk.default_address();
    let div_bytes = default_addr.diversifier().0;
    eprintln!("DEBUG: IVK scalar = {:?}", ivk.0.to_repr());
    eprintln!("DEBUG: Default diversifier = {:02x?}", div_bytes);

    // Debug: print the full address bytes and pk_d to verify
    let addr_bytes = default_addr.to_bytes();
    eprintln!("DEBUG: Full address bytes[0..8] = {:02x?}", &addr_bytes[0..8]);
    // Use GroupEncoding trait to get bytes
    let pk_d_bytes = default_addr.pk_d().inner().to_bytes();
    eprintln!("DEBUG: pk_d bytes = {:02x?}", pk_d_bytes);

    // Verify IVK by manually computing [ivk] g_d and comparing to pk_d
    if let Some(g_d) = default_addr.diversifier().g_d() {
        let computed_pk_d = g_d * ivk.0;
        let computed_pk_d_bytes = computed_pk_d.to_bytes();
        if computed_pk_d_bytes == pk_d_bytes {
            eprintln!("DEBUG: ✅ IVK verification: [ivk] g_d == pk_d");
        } else {
            eprintln!("DEBUG: ❌ IVK verification FAILED!");
            eprintln!("DEBUG: Expected pk_d = {:02x?}", pk_d_bytes);
            eprintln!("DEBUG: Computed pk_d = {:02x?}", computed_pk_d_bytes);
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
    eprintln!("DEBUG: EPK[0..4] = {:02x?}", &epk_bytes[0..4]);
    eprintln!("DEBUG: CMU[0..4] = {:02x?}", &cmu_bytes[0..4]);
    eprintln!("DEBUG: ENC[0..4] = {:02x?}", &enc_bytes[0..4]);
    eprintln!("DEBUG: About to parse EPK as curve point...");

    // Debug: try to parse EPK as a curve point
    let epk_point_opt = jubjub::ExtendedPoint::from_bytes(&epk_bytes);
    eprintln!("DEBUG: EPK parsing complete");
    let epk_valid: bool = epk_point_opt.is_some().into();
    if epk_valid {
        eprintln!("DEBUG: ✅ EPK is valid curve point");
    } else {
        eprintln!("DEBUG: ❌ EPK is NOT a valid curve point!");
        return 0;
    }
    let epk_point = epk_point_opt.unwrap();

    // Manual KDF to debug decryption
    // ka = [8] * (ivk * epk) - matches zcash_primitives spec.rs line 135
    // The library does: (b * sk).clear_cofactor()
    let ka = (epk_point * ivk.0).clear_cofactor();
    let ka_bytes = jubjub::ExtendedPoint::from(ka).to_affine().to_bytes();
    eprintln!("DEBUG: KA (shared secret) first 4 bytes: {:02x?}", &ka_bytes[0..4]);

    // Also print full EPK and IVK for verification
    eprintln!("DEBUG: Full EPK = {:02x?}", epk_bytes);
    eprintln!("DEBUG: Full IVK = {:02x?}", ivk.0.to_repr());

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

    eprintln!("DEBUG: KDF key first 4 bytes: {:02x?}", &key.as_bytes()[0..4]);

    // Try ChaCha20Poly1305 decryption
    let cipher_key = GenericArray::from_slice(key.as_bytes());
    let cipher = ChaCha20Poly1305::new(cipher_key);
    let nonce = GenericArray::from_slice(&[0u8; 12]);

    // The enc_ciphertext is 580 bytes = 564 plaintext + 16 tag
    match cipher.decrypt(nonce, &enc_bytes[..]) {
        Ok(plaintext) => {
            eprintln!("DEBUG: ✅ Manual decryption succeeded! Plaintext len: {}", plaintext.len());
            eprintln!("DEBUG: Plaintext version byte: 0x{:02x}", plaintext[0]);
            eprintln!("DEBUG: Plaintext diversifier: {:02x?}", &plaintext[1..12]);

            // Check version byte
            if plaintext[0] != 0x01 && plaintext[0] != 0x02 {
                eprintln!("DEBUG: ❌ Invalid version byte!");
            }

            // Extract value (bytes 12-20, little-endian u64)
            let value = u64::from_le_bytes(plaintext[12..20].try_into().unwrap());
            eprintln!("DEBUG: Decrypted value: {} zatoshis ({} ZCL)", value, value as f64 / 100_000_000.0);

            // Check if diversifier matches our address
            let our_div = default_addr.diversifier().0;
            if plaintext[1..12] == our_div {
                eprintln!("DEBUG: ✅ Diversifier MATCHES! This note is for us!");
            } else {
                eprintln!("DEBUG: ❌ Diversifier does not match. Note is for someone else.");
                eprintln!("DEBUG: Expected: {:02x?}", our_div);
                eprintln!("DEBUG: Got:      {:02x?}", &plaintext[1..12]);
            }
        }
        Err(_e) => {
            eprintln!("DEBUG: ❌ ChaCha20Poly1305 auth tag verification failed");
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
    eprintln!("DEBUG: Now trying zcash_primitives decryption...");

    match try_sapling_note_decryption(&ZclassicNetwork, height, &prepared_ivk, &shielded_output) {
        Some((note, address, memo)) => {
            eprintln!("✅ DECRYPTION SUCCESS! Value: {} zatoshis", note.value().inner());
            // Successfully decrypted! Pack the result
            // Format: diversifier(11) + value(8) + rcm(32) + memo(512)
            let diversifier = address.diversifier().0;
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
    2 // Version 2 with real crypto
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
    eprintln!("✅ Prover initialized with Sapling parameters");
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

    // Get sender's address
    let (_, from_addr) = extsk.default_address();

    // Calculate fee
    let fee = 10000u64;

    // Verify funds
    if note_value < amount + fee {
        eprintln!("❌ Insufficient funds: have {}, need {}", note_value, amount + fee);
        return false;
    }

    // Create note to spend
    let note = zcash_primitives::sapling::Note::from_parts(
        from_addr,
        NoteValue::from_raw(note_value),
        Rseed::BeforeZip212(rcm),
    );

    // Deserialize merkle path from witness data
    // Format: 4 bytes position (little endian) + 32 * 32 bytes for path elements
    if witness_slice.len() < 4 + 32 * 32 {
        eprintln!("❌ Witness data too short: {} bytes", witness_slice.len());
        return false;
    }

    let position = u32::from_le_bytes(witness_slice[0..4].try_into().unwrap());
    let mut path_hashes = Vec::with_capacity(32);

    for i in 0..32 {
        let start = 4 + i * 32;
        let end = start + 32;
        let mut hash = [0u8; 32];
        hash.copy_from_slice(&witness_slice[start..end]);

        // Convert to Node (Sapling commitment tree node)
        let scalar = match Option::<bls12_381::Scalar>::from(bls12_381::Scalar::from_repr(hash)) {
            Some(s) => s,
            None => {
                eprintln!("❌ Invalid merkle path scalar at index {}", i);
                return false;
            }
        };
        let node = zcash_primitives::sapling::Node::from_scalar(scalar);
        path_hashes.push(node);
    }

    let merkle_path = match MerklePath::from_parts(path_hashes, Position::from(position as u64)) {
        Ok(p) => p,
        Err(_) => {
            eprintln!("❌ Failed to create merkle path");
            return false;
        }
    };

    // Create transaction builder
    // Use a recent block height for Sapling
    let target_height = BlockHeight::from_u32(2900000);
    let mut builder = Builder::new(ZclassicNetwork, target_height, None);

    // Add spend
    if let Err(e) = builder.add_sapling_spend(
        extsk.clone(),
        diversifier,
        note,
        merkle_path,
    ) {
        eprintln!("❌ Failed to add spend: {:?}", e);
        return false;
    }

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
        if let Err(e) = builder.add_sapling_output(
            Some(extsk.expsk.ovk),
            from_addr,
            change_amount,
            change_memo,
        ) {
            eprintln!("❌ Failed to add change output: {:?}", e);
            return false;
        }
    }

    // Build the transaction with proofs
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

    eprintln!("✅ Transaction built: {} bytes", tx_bytes.len());

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
/// cmu: 32-byte note commitment
/// Returns the position of the added commitment
#[no_mangle]
pub unsafe extern "C" fn zipherx_tree_append(cmu: *const u8) -> u64 {
    let cmu_slice = slice::from_raw_parts(cmu, 32);

    let mut tree_guard = COMMITMENT_TREE.lock().unwrap();
    let tree = match tree_guard.as_mut() {
        Some(t) => t,
        None => return u64::MAX, // Tree not initialized
    };

    // Parse cmu as a Sapling Node
    let mut cmu_bytes = [0u8; 32];
    cmu_bytes.copy_from_slice(cmu_slice);

    let node = match bls12_381::Scalar::from_repr(cmu_bytes).into() {
        Some(scalar) => zcash_primitives::sapling::Node::from_scalar(scalar),
        None => return u64::MAX,
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
            eprintln!("❌ Invalid witness index {}", witness_index);
            return false;
        }
    };

    // Get merkle path from witness
    let path = match witness.path() {
        Some(p) => p,
        None => {
            eprintln!("❌ Failed to get path from witness");
            return false;
        }
    };

    // Serialize witness
    // Format: 4 bytes position (little endian) + 32 * 32 bytes for path elements
    let position = u64::from(witness.tip_position()) as u32;
    let pos_bytes = position.to_le_bytes();
    std::ptr::copy_nonoverlapping(pos_bytes.as_ptr(), witness_out, 4);

    // Get path hashes
    let path_hashes = path.path_elems();

    for (i, node) in path_hashes.iter().enumerate() {
        let mut node_bytes = Vec::new();
        node.write(&mut node_bytes).unwrap();
        std::ptr::copy_nonoverlapping(
            node_bytes.as_ptr(),
            witness_out.add(4 + i * 32),
            32
        );
    }

    // Pad remaining slots with zeros if path is shorter than 32
    for i in path_hashes.len()..32 {
        std::ptr::write_bytes(witness_out.add(4 + i * 32), 0, 32);
    }

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
        eprintln!("❌ Tree too large to serialize");
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
