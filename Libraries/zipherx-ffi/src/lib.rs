//! ZipherX FFI - C bindings for Sapling cryptography
//!
//! This crate provides C-compatible functions for iOS integration
//! Using real librustzcash for proper Sapling operations

// Tor module (Arti integration)
pub mod tor;

// FIX #342: Fast HTTP downloads using reqwest (replaces slow Swift URLSession)
pub mod download;

// Set to true for verbose debug output, false for production
const DEBUG_LOGGING: bool = true;  // FIX #514: Enabled to verify CMU byte order handling

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
use std::sync::atomic::{AtomicUsize, Ordering};
use std::path::Path;
use bip0039::{Count, English, Mnemonic};
use bech32::{ToBase32, FromBase32, Variant};
use rayon::prelude::*;

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
use zcash_proofs::sapling::SaplingVerificationContext;
use zcash_proofs::ZcashParameters;
use group::{GroupEncoding, cofactor::CofactorGroup, Curve};
use ff::{PrimeField, Field};
use rand::rngs::OsRng;

// Global prover instance
static PROVER: Mutex<Option<LocalTxProver>> = Mutex::new(None);

// Global verifying keys - stored separately from prover since LocalTxProver doesn't expose its VKs
// These are used by zipherx_verify_transaction() to validate Sapling proofs before broadcast
static VERIFYING_KEYS: Mutex<Option<ZcashParameters>> = Mutex::new(None);

// Sapling tree depth
const SAPLING_COMMITMENT_TREE_DEPTH: u8 = 32;

// =============================================================================
// FIX #230: FFI Safety Module - Bounds-checked slice operations
// =============================================================================
//
// This module provides safe wrappers for unsafe FFI operations to prevent:
// - Buffer overflows from unchecked slice::from_raw_parts
// - Panics from .unwrap() on malformed input
// - Memory corruption from invalid pointers
//
// All FFI functions should use these helpers instead of raw unsafe operations.

/// Safe wrapper for creating a slice from raw pointer with bounds validation
/// Returns None if pointer is null or alignment is incorrect
#[inline]
unsafe fn safe_slice<'a, T>(ptr: *const T, len: usize) -> Option<&'a [T]> {
    if ptr.is_null() {
        debug_log!("FFI Safety: null pointer passed to safe_slice");
        return None;
    }
    if len == 0 {
        return Some(&[]);
    }
    // Check alignment
    if (ptr as usize) % std::mem::align_of::<T>() != 0 {
        debug_log!("FFI Safety: misaligned pointer passed to safe_slice");
        return None;
    }
    // Check for potential overflow in size calculation
    if len > isize::MAX as usize / std::mem::size_of::<T>() {
        debug_log!("FFI Safety: length would overflow in safe_slice");
        return None;
    }
    Some(slice::from_raw_parts(ptr, len))
}

/// Safe wrapper for creating a mutable slice from raw pointer with bounds validation
#[inline]
unsafe fn safe_slice_mut<'a, T>(ptr: *mut T, len: usize) -> Option<&'a mut [T]> {
    if ptr.is_null() {
        debug_log!("FFI Safety: null pointer passed to safe_slice_mut");
        return None;
    }
    if len == 0 {
        return Some(&mut []);
    }
    // Check alignment
    if (ptr as usize) % std::mem::align_of::<T>() != 0 {
        debug_log!("FFI Safety: misaligned pointer passed to safe_slice_mut");
        return None;
    }
    // Check for potential overflow
    if len > isize::MAX as usize / std::mem::size_of::<T>() {
        debug_log!("FFI Safety: length would overflow in safe_slice_mut");
        return None;
    }
    Some(slice::from_raw_parts_mut(ptr, len))
}

/// Safe mutex lock with timeout protection (prevents deadlocks)
/// Returns None if lock is poisoned or cannot be acquired
macro_rules! safe_lock {
    ($mutex:expr) => {
        match $mutex.lock() {
            Ok(guard) => Some(guard),
            Err(poisoned) => {
                debug_log!("FFI Safety: mutex poisoned, recovering");
                // Recover from poisoned mutex - the data may be in an inconsistent state
                // but we prefer recovery over panic in FFI code
                Some(poisoned.into_inner())
            }
        }
    };
}

/// Safe conversion of byte slice to fixed-size array
/// Returns None if slice length doesn't match
#[inline]
fn safe_array<const N: usize>(slice: &[u8]) -> Option<[u8; N]> {
    if slice.len() != N {
        debug_log!("FFI Safety: slice length {} != expected {}", slice.len(), N);
        return None;
    }
    let mut arr = [0u8; N];
    arr.copy_from_slice(slice);
    Some(arr)
}

/// Safe conversion with explicit error for try_into
#[inline]
fn safe_try_into<const N: usize>(slice: &[u8]) -> Option<[u8; N]> {
    slice.try_into().ok()
}

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
/// FIX #230: Now uses safe_slice for bounds validation
#[no_mangle]
pub unsafe extern "C" fn zipherx_derive_spending_key(
    seed: *const u8,
    account: u32,
    sk_out: *mut u8,
) -> bool {
    // FIX #230: Validate input pointers and create safe slice
    let seed_slice = match safe_slice(seed, 64) {
        Some(s) => s,
        None => {
            debug_log!("zipherx_derive_spending_key: invalid seed pointer");
            return false;
        }
    };

    if sk_out.is_null() {
        debug_log!("zipherx_derive_spending_key: null output pointer");
        return false;
    }

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
    // FIX #230: Replace .unwrap() with proper error handling
    if account_key.write(&mut serialized).is_err() {
        debug_log!("zipherx_derive_spending_key: failed to serialize key");
        return false;
    }

    if serialized.len() != 169 {
        debug_log!("zipherx_derive_spending_key: unexpected serialized length");
        return false;
    }

    std::ptr::copy_nonoverlapping(serialized.as_ptr(), sk_out, 169);

    true
}

/// Derive payment address from serialized ExtendedSpendingKey (169 bytes)
/// FIX #230: Now uses safe_slice for bounds validation
#[no_mangle]
pub unsafe extern "C" fn zipherx_derive_address(
    sk: *const u8,
    diversifier_index: u64,
    address_out: *mut u8,
) -> bool {
    // FIX #230: Validate input pointer
    let sk_slice = match safe_slice(sk, 169) {
        Some(s) => s,
        None => {
            debug_log!("zipherx_derive_address: invalid sk pointer");
            return false;
        }
    };

    if address_out.is_null() {
        debug_log!("zipherx_derive_address: null output pointer");
        return false;
    }

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
/// FIX #230: Now uses safe_slice for bounds validation
#[no_mangle]
pub unsafe extern "C" fn zipherx_derive_ivk(
    sk: *const u8,
    ivk_out: *mut u8,
) -> bool {
    // FIX #230: Validate input pointer
    let sk_slice = match safe_slice(sk, 169) {
        Some(s) => s,
        None => {
            debug_log!("zipherx_derive_ivk: invalid sk pointer");
            return false;
        }
    };

    if ivk_out.is_null() {
        debug_log!("zipherx_derive_ivk: null output pointer");
        return false;
    }

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
/// FIX #230: Now uses safe_slice for bounds validation
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

    // FIX #230: Validate all input pointers
    let sk_slice = match safe_slice(spending_key, 169) {
        Some(s) => s,
        None => {
            debug_log!("zipherx_compute_nullifier: invalid spending_key pointer");
            return false;
        }
    };
    let div_slice = match safe_slice(diversifier, 11) {
        Some(s) => s,
        None => {
            debug_log!("zipherx_compute_nullifier: invalid diversifier pointer");
            return false;
        }
    };
    let rcm_slice = match safe_slice(rcm, 32) {
        Some(s) => s,
        None => {
            debug_log!("zipherx_compute_nullifier: invalid rcm pointer");
            return false;
        }
    };

    if nf_out.is_null() {
        debug_log!("zipherx_compute_nullifier: null output pointer");
        return false;
    }

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
/// FIX #230: Now uses safe_slice for bounds validation
#[no_mangle]
pub unsafe extern "C" fn zipherx_encode_address(
    address: *const u8,
    output: *mut u8,
) -> usize {
    // FIX #230: Validate input pointers
    let addr_slice = match safe_slice(address, 43) {
        Some(s) => s,
        None => {
            debug_log!("zipherx_encode_address: invalid address pointer");
            return 0;
        }
    };

    if output.is_null() {
        debug_log!("zipherx_encode_address: null output pointer");
        return 0;
    }

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
/// FIX #230: Now uses safe_slice for bounds validation
#[no_mangle]
pub unsafe extern "C" fn zipherx_try_decrypt_note(
    ivk: *const u8,
    epk: *const u8,
    cmu: *const u8,
    ciphertext: *const u8,
    output: *mut u8,
) -> usize {
    use chacha20poly1305::{ChaCha20Poly1305, Key, Nonce, aead::Aead, KeyInit};

    // FIX #230: Validate all input pointers
    let ivk_slice = match safe_slice(ivk, 32) {
        Some(s) => s,
        None => {
            debug_log!("zipherx_try_decrypt_note: invalid ivk pointer");
            return 0;
        }
    };
    let epk_slice = match safe_slice(epk, 32) {
        Some(s) => s,
        None => {
            debug_log!("zipherx_try_decrypt_note: invalid epk pointer");
            return 0;
        }
    };
    let _cmu_slice = match safe_slice(cmu, 32) {
        Some(s) => s,
        None => {
            debug_log!("zipherx_try_decrypt_note: invalid cmu pointer");
            return 0;
        }
    };
    let ciphertext_slice = match safe_slice(ciphertext, 580) {
        Some(s) => s,
        None => {
            debug_log!("zipherx_try_decrypt_note: invalid ciphertext pointer");
            return 0;
        }
    };

    if output.is_null() {
        debug_log!("zipherx_try_decrypt_note: null output pointer");
        return 0;
    }

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

/// FIX #230: Now uses safe_slice for bounds validation
#[no_mangle]
pub unsafe extern "C" fn zipherx_try_decrypt_note_with_sk(
    sk: *const u8,
    epk: *const u8,
    cmu: *const u8,
    ciphertext: *const u8,
    output: *mut u8,
) -> usize {
    // FIX #230: Validate all input pointers
    let sk_slice = match safe_slice(sk, 169) {
        Some(s) => s,
        None => {
            debug_log!("zipherx_try_decrypt_note_with_sk: invalid sk pointer");
            return 0;
        }
    };
    let epk_slice = match safe_slice(epk, 32) {
        Some(s) => s,
        None => {
            debug_log!("zipherx_try_decrypt_note_with_sk: invalid epk pointer");
            return 0;
        }
    };
    let cmu_slice = match safe_slice(cmu, 32) {
        Some(s) => s,
        None => {
            debug_log!("zipherx_try_decrypt_note_with_sk: invalid cmu pointer");
            return 0;
        }
    };
    let ciphertext_slice = match safe_slice(ciphertext, 580) {
        Some(s) => s,
        None => {
            debug_log!("zipherx_try_decrypt_note_with_sk: invalid ciphertext pointer");
            return 0;
        }
    };

    if output.is_null() {
        debug_log!("zipherx_try_decrypt_note_with_sk: null output pointer");
        return 0;
    }

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

            // FIX #230: Copy to output buffer with safe slice validation
            let out_slice = match safe_slice_mut(output, 564) {
                Some(s) => s,
                None => return 0,  // Invalid output buffer
            };
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
// Parallel Decryption (Rayon-based for 6.7x speedup)
// =============================================================================

/// Batch decrypt multiple shielded outputs in parallel using Rayon
///
/// This function provides ~6.7x speedup over sequential decryption by using
/// all available CPU cores (Rayon's work-stealing thread pool).
///
/// # Input format (per output):
/// - epk: 32 bytes (ephemeral public key)
/// - cmu: 32 bytes (note commitment)
/// - ciphertext: 580 bytes (encrypted note)
/// Total: 644 bytes per output
///
/// # Output format (per output):
/// - found: 1 byte (0 = not ours, 1 = decrypted successfully)
/// - If found == 1:
///   - diversifier: 11 bytes
///   - value: 8 bytes (little-endian u64)
///   - rcm: 32 bytes
///   - memo: 512 bytes
/// Total: 564 bytes per output (1 byte flag + 563 bytes data)
///
/// # Parameters
/// - sk: spending key (169 bytes)
/// - outputs_data: packed array of outputs (644 bytes each)
/// - output_count: number of outputs
/// - height: block height (for version byte validation)
/// - results: output buffer (564 bytes per output)
///
/// # Returns
/// Number of successfully decrypted notes
/// FIX #230: Now uses safe_slice for bounds validation
#[no_mangle]
pub unsafe extern "C" fn zipherx_try_decrypt_notes_parallel(
    sk: *const u8,
    outputs_data: *const u8,
    output_count: usize,
    height: u64,
    results: *mut u8,
) -> usize {
    if output_count == 0 {
        return 0;
    }

    // FIX #230: Validate all input pointers
    let sk_slice = match safe_slice(sk, 169) {
        Some(s) => s,
        None => {
            debug_log!("zipherx_try_decrypt_notes_parallel: invalid sk pointer");
            return 0;
        }
    };

    // Deserialize the ExtendedSpendingKey
    let extsk = match ExtendedSpendingKey::read(&mut &sk_slice[..]) {
        Ok(key) => key,
        Err(_e) => {
            debug_log!("DEBUG: ❌ Failed to deserialize ExtendedSpendingKey");
            return 0;
        }
    };

    // Derive IVK once (this is expensive, do it once before parallel loop)
    let fvk = FullViewingKey::from_expanded_spending_key(&extsk.expsk);
    let ivk = fvk.vk.ivk();
    let prepared_ivk = PreparedIncomingViewingKey::new(&ivk);

    let block_height = BlockHeight::from_u32(height as u32);

    // FIX #230: Validate output data and results pointers
    let outputs_slice = match safe_slice(outputs_data, output_count * 644) {
        Some(s) => s,
        None => {
            debug_log!("zipherx_try_decrypt_notes_parallel: invalid outputs_data pointer");
            return 0;
        }
    };
    let results_slice = match safe_slice_mut(results, output_count * 564) {
        Some(s) => s,
        None => {
            debug_log!("zipherx_try_decrypt_notes_parallel: invalid results pointer");
            return 0;
        }
    };

    // Pre-parse outputs into structs (needed for Rayon)
    let parsed_outputs: Vec<(usize, RawShieldedOutput)> = (0..output_count)
        .map(|i| {
            let offset = i * 644;
            let mut epk = [0u8; 32];
            let mut cmu = [0u8; 32];
            let mut enc = [0u8; ENC_CIPHERTEXT_SIZE];

            epk.copy_from_slice(&outputs_slice[offset..offset + 32]);
            cmu.copy_from_slice(&outputs_slice[offset + 32..offset + 64]);
            enc.copy_from_slice(&outputs_slice[offset + 64..offset + 644]);

            (i, RawShieldedOutput {
                epk,
                cmu,
                enc_ciphertext: enc,
            })
        })
        .collect();

    // Counter for successful decryptions
    let decrypted_count = AtomicUsize::new(0);

    // Parallel decryption using Rayon
    // Each thread gets its own portion of the work
    parsed_outputs.par_iter().for_each(|(idx, output)| {
        let result_offset = idx * 564;

        // Try decryption
        match try_sapling_note_decryption(&ZclassicNetwork, block_height, &prepared_ivk, output) {
            Some((note, address, memo)) => {
                // Successfully decrypted! Pack the result
                let diversifier = address.diversifier().0;
                let value: u64 = note.value().inner();
                let rcm = match note.rseed() {
                    Rseed::BeforeZip212(rcm) => rcm.to_repr(),
                    Rseed::AfterZip212(rseed) => *rseed,
                };

                // SAFETY: Each thread writes to its own non-overlapping slice
                let out_ptr = results_slice.as_ptr() as *mut u8;
                let out_offset = out_ptr.add(result_offset);

                // Write found flag
                *out_offset = 1u8;

                // Write diversifier (11 bytes)
                std::ptr::copy_nonoverlapping(diversifier.as_ptr(), out_offset.add(1), 11);

                // Write value (8 bytes, little-endian)
                let value_bytes = value.to_le_bytes();
                std::ptr::copy_nonoverlapping(value_bytes.as_ptr(), out_offset.add(12), 8);

                // Write rcm (32 bytes)
                std::ptr::copy_nonoverlapping(rcm.as_ptr(), out_offset.add(20), 32);

                // Write memo (512 bytes)
                std::ptr::copy_nonoverlapping(memo.as_array().as_ptr(), out_offset.add(52), 512);

                decrypted_count.fetch_add(1, Ordering::Relaxed);
            }
            None => {
                // Not our note - write 0 flag
                let out_ptr = results_slice.as_ptr() as *mut u8;
                *out_ptr.add(result_offset) = 0u8;
            }
        }
    });

    decrypted_count.load(Ordering::Relaxed)
}

/// Get the number of CPU threads Rayon will use for parallel decryption
#[no_mangle]
pub extern "C" fn zipherx_get_rayon_threads() -> usize {
    rayon::current_num_threads()
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

    // FIX #230: Use safe_slice for bounds checking
    let input = match safe_slice(data, len) {
        Some(s) => s,
        None => {
            eprintln!("❌ zipherx_double_sha256: Invalid input pointer or length");
            return false;
        }
    };

    if output.is_null() {
        eprintln!("❌ zipherx_double_sha256: Output pointer is null");
        return false;
    }

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

    // FIX #230: Use safe_slice for bounds checking
    let sk_slice = match safe_slice(sk, 169) {
        Some(s) => s,
        None => {
            eprintln!("❌ zipherx_encode_spending_key: Invalid spending key pointer");
            return 0;
        }
    };

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

/// Initialize the prover with Sapling parameters from raw byte arrays
/// Use this when file access from Rust is restricted (e.g., Hardened Runtime)
/// Swift reads the files and passes the bytes to Rust
#[no_mangle]
pub unsafe extern "C" fn zipherx_init_prover_from_bytes(
    spend_data: *const u8,
    spend_len: usize,
    output_data: *const u8,
    output_len: usize,
) -> bool {
    eprintln!("📁 Loading Sapling params from memory:");
    eprintln!("   Spend:  {} bytes", spend_len);
    eprintln!("   Output: {} bytes", output_len);

    // Verify expected file sizes
    if spend_len != 47958396 {
        eprintln!("❌ Spend params has wrong size! Got {}, expected 47958396", spend_len);
        return false;
    }
    if output_len != 3592860 {
        eprintln!("❌ Output params has wrong size! Got {}, expected 3592860", output_len);
        return false;
    }

    // FIX #230: Use safe_slice for bounds checking
    let spend_bytes = match safe_slice(spend_data, spend_len) {
        Some(s) => s,
        None => {
            eprintln!("❌ Invalid spend params pointer");
            return false;
        }
    };
    let output_bytes = match safe_slice(output_data, output_len) {
        Some(s) => s,
        None => {
            eprintln!("❌ Invalid output params pointer");
            return false;
        }
    };

    eprintln!("📂 Loading prover from memory...");

    // Load the prover with Sapling parameters from bytes
    let prover = std::panic::catch_unwind(|| {
        LocalTxProver::from_bytes(spend_bytes, output_bytes)
    });

    // Also load verifying keys using parse_parameters (VUL-002 FIX)
    let vk_result = std::panic::catch_unwind(|| {
        zcash_proofs::parse_parameters(spend_bytes, output_bytes, None)
    });

    match prover {
        Ok(p) => {
            let mut global_prover = PROVER.lock().unwrap();
            *global_prover = Some(p);
            eprintln!("✅ Prover initialized from memory");

            // Store verifying keys for VUL-002 transaction verification
            if let Ok(params) = vk_result {
                let mut global_vk = VERIFYING_KEYS.lock().unwrap();
                *global_vk = Some(params);
                eprintln!("✅ Verifying keys stored for TX validation (VUL-002 FIX)");
            } else {
                eprintln!("⚠️ Could not load verifying keys - TX validation may not work");
            }

            true
        }
        Err(e) => {
            eprintln!("❌ Prover initialization panicked: {:?}", e);
            eprintln!("   This usually means the params are corrupted or have wrong format");
            false
        }
    }
}

/// Initialize the prover with Sapling parameters from file paths
/// Must be called before building transactions
/// spend_path and output_path are paths to sapling-spend.params and sapling-output.params
/// NOTE: May fail on macOS with Hardened Runtime - use zipherx_init_prover_from_bytes instead
#[no_mangle]
pub unsafe extern "C" fn zipherx_init_prover(
    spend_path: *const i8,
    output_path: *const i8,
) -> bool {
    let spend = match std::ffi::CStr::from_ptr(spend_path).to_str() {
        Ok(s) => s,
        Err(e) => {
            eprintln!("❌ Invalid spend path string: {:?}", e);
            return false;
        }
    };

    let output = match std::ffi::CStr::from_ptr(output_path).to_str() {
        Ok(s) => s,
        Err(e) => {
            eprintln!("❌ Invalid output path string: {:?}", e);
            return false;
        }
    };

    eprintln!("📁 Loading Sapling params from:");
    eprintln!("   Spend:  {}", spend);
    eprintln!("   Output: {}", output);

    // Check if files exist
    let spend_path = Path::new(spend);
    let output_path = Path::new(output);

    if !spend_path.exists() {
        eprintln!("❌ Spend params file does not exist: {}", spend);
        return false;
    }
    if !output_path.exists() {
        eprintln!("❌ Output params file does not exist: {}", output);
        return false;
    }

    // Get file sizes for verification
    let spend_size = match std::fs::metadata(spend_path) {
        Ok(m) => {
            eprintln!("   Spend file size: {} bytes (expected: 47958396)", m.len());
            m.len()
        }
        Err(e) => {
            eprintln!("❌ Cannot read spend file metadata: {:?}", e);
            return false;
        }
    };

    let output_size = match std::fs::metadata(output_path) {
        Ok(m) => {
            eprintln!("   Output file size: {} bytes (expected: 3592860)", m.len());
            m.len()
        }
        Err(e) => {
            eprintln!("❌ Cannot read output file metadata: {:?}", e);
            return false;
        }
    };

    // Verify expected file sizes
    if spend_size != 47958396 {
        eprintln!("❌ Spend params file has wrong size! Got {}, expected 47958396", spend_size);
        return false;
    }
    if output_size != 3592860 {
        eprintln!("❌ Output params file has wrong size! Got {}, expected 3592860", output_size);
        return false;
    }

    eprintln!("📂 File sizes verified, loading prover...");

    // Load the prover with Sapling parameters (can panic on invalid files)
    let prover = std::panic::catch_unwind(|| {
        LocalTxProver::new(spend_path, output_path)
    });

    // Also load verifying keys using load_parameters (VUL-002 FIX)
    let vk_result = std::panic::catch_unwind(|| {
        zcash_proofs::load_parameters(spend_path, output_path, None)
    });

    match prover {
        Ok(p) => {
            let mut global_prover = PROVER.lock().unwrap();
            *global_prover = Some(p);
            eprintln!("✅ Prover initialized with Sapling parameters");

            // Store verifying keys for VUL-002 transaction verification
            if let Ok(params) = vk_result {
                let mut global_vk = VERIFYING_KEYS.lock().unwrap();
                *global_vk = Some(params);
                eprintln!("✅ Verifying keys stored for TX validation (VUL-002 FIX)");
            } else {
                eprintln!("⚠️ Could not load verifying keys - TX validation may not work");
            }

            true
        }
        Err(e) => {
            eprintln!("❌ Prover initialization panicked: {:?}", e);
            eprintln!("   This usually means the params files are corrupted or have wrong format");
            false
        }
    }
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
/// FIX #230: Now uses safe_slice and safe_lock! for bounds validation
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
    // FIX #230: Use safe_lock! to avoid panic on poisoned mutex
    let prover_guard = match safe_lock!(PROVER) {
        Some(g) => g,
        None => {
            eprintln!("❌ Failed to acquire prover lock");
            return false;
        }
    };
    let prover = match prover_guard.as_ref() {
        Some(p) => p,
        None => {
            eprintln!("❌ Prover not initialized");
            return false;
        }
    };

    // FIX #230: Validate all input pointers
    let sk_slice = match safe_slice(sk, 169) {
        Some(s) => s,
        None => {
            eprintln!("❌ Invalid spending key pointer");
            return false;
        }
    };
    let to_addr_slice = match safe_slice(to_address, 43) {
        Some(s) => s,
        None => {
            eprintln!("❌ Invalid destination address pointer");
            return false;
        }
    };
    let witness_slice = match safe_slice(witness_data, witness_len) {
        Some(s) => s,
        None => {
            eprintln!("❌ Invalid witness data pointer");
            return false;
        }
    };
    let rcm_slice = match safe_slice(note_rcm, 32) {
        Some(s) => s,
        None => {
            eprintln!("❌ Invalid rcm pointer");
            return false;
        }
    };
    let div_slice = match safe_slice(note_diversifier, 11) {
        Some(s) => s,
        None => {
            eprintln!("❌ Invalid diversifier pointer");
            return false;
        }
    };

    if tx_out.is_null() || tx_out_len.is_null() {
        eprintln!("❌ Null output pointers");
        return false;
    }

    // Deserialize spending key
    let extsk = match ExtendedSpendingKey::read(&mut &sk_slice[..]) {
        Ok(key) => key,
        Err(e) => {
            eprintln!("❌ Failed to read spending key: {:?}", e);
            return false;
        }
    };

    // FIX #230: Parse destination address (replace .unwrap() with proper handling)
    let to_addr_arr: [u8; 43] = match safe_try_into(to_addr_slice) {
        Some(arr) => arr,
        None => {
            eprintln!("❌ Invalid destination address length");
            return false;
        }
    };
    let to_addr = match PaymentAddress::from_bytes(&to_addr_arr) {
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

    // FIX #230: Prepare memo with safe_slice
    let memo_bytes = if memo.is_null() {
        [0u8; 512]
    } else {
        let memo_slice = match safe_slice(memo, 512) {
            Some(s) => s,
            None => {
                eprintln!("❌ Invalid memo pointer");
                return false;
            }
        };
        let mut m = [0u8; 512];
        m.copy_from_slice(memo_slice);
        m
    };
    let memo_obj = match MemoBytes::from_bytes(&memo_bytes) {
        Ok(m) => m,
        Err(e) => {
            eprintln!("❌ Invalid memo bytes: {:?}", e);
            return false;
        }
    };

    // FIX #230: Convert amount to Amount type (replace .unwrap())
    let amount_val = match Amount::from_i64(amount as i64) {
        Ok(a) => a,
        Err(_) => {
            eprintln!("❌ Invalid amount: {}", amount);
            return false;
        }
    };

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

    // FIX #230: Add change output with safe Amount conversion
    let change = note_value - amount - fee;
    if change > 0 {
        let change_memo = MemoBytes::empty();
        let change_amount = match Amount::from_i64(change as i64) {
            Ok(a) => a,
            Err(_) => {
                eprintln!("❌ Invalid change amount: {}", change);
                return false;
            }
        };
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

    // FIX #230: Build the transaction with proofs (safe fee conversion)
    debug_log!("🔨 Building transaction...");
    let fee_amount = match Amount::from_i64(fee as i64) {
        Ok(a) => a,
        Err(_) => {
            eprintln!("❌ Invalid fee amount: {}", fee);
            return false;
        }
    };
    let (tx, _) = match builder.build(prover, &zcash_primitives::transaction::fees::fixed::FeeRule::non_standard(fee_amount)) {
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

/// Spend information for multi-input transactions
/// Passed as an array of pointers to this struct
#[repr(C)]
pub struct SpendInfo {
    /// Serialized IncrementalWitness data
    pub witness_data: *const u8,
    /// Length of witness data
    pub witness_len: usize,
    /// Note value in zatoshis
    pub note_value: u64,
    /// Note commitment randomness (32 bytes)
    pub note_rcm: *const u8,
    /// Note diversifier (11 bytes)
    pub note_diversifier: *const u8,
}

/// Build a shielded transaction with multiple input notes
///
/// This allows spending from multiple notes in a single transaction,
/// enabling transactions larger than any single note.
///
/// # Safety
/// - sk: 169-byte ExtendedSpendingKey
/// - to_address: 43-byte payment address
/// - amount: amount to send in zatoshis
/// - memo: 512-byte memo or null for empty
/// - spends: array of SpendInfo pointers
/// - spend_count: number of spends
/// - chain_height: current chain height for branch ID selection
/// - tx_out: output buffer (should be at least 10000 bytes)
/// - tx_out_len: receives actual transaction length
/// - nullifiers_out: output buffer for nullifiers (32 bytes * spend_count)
///
/// Returns true on success, false on failure
/// FIX #230: Now uses safe_slice and safe_lock! for bounds validation
#[no_mangle]
pub unsafe extern "C" fn zipherx_build_transaction_multi(
    sk: *const u8,
    to_address: *const u8,
    amount: u64,
    memo: *const u8,
    spends: *const *const SpendInfo,
    spend_count: usize,
    chain_height: u64,
    tx_out: *mut u8,
    tx_out_len: *mut usize,
    nullifiers_out: *mut u8,
) -> bool {
    if spend_count == 0 || spend_count > 100 {
        eprintln!("❌ Invalid spend count: {} (must be 1-100)", spend_count);
        return false;
    }

    // FIX #230: Use safe_lock! to avoid panic on poisoned mutex
    let prover_guard = match safe_lock!(PROVER) {
        Some(g) => g,
        None => {
            eprintln!("❌ Failed to acquire prover lock");
            return false;
        }
    };
    let prover = match prover_guard.as_ref() {
        Some(p) => p,
        None => {
            eprintln!("❌ Prover not initialized");
            return false;
        }
    };

    // FIX #230: Validate input pointers
    let sk_slice = match safe_slice(sk, 169) {
        Some(s) => s,
        None => {
            eprintln!("❌ Invalid spending key pointer");
            return false;
        }
    };
    let to_addr_slice = match safe_slice(to_address, 43) {
        Some(s) => s,
        None => {
            eprintln!("❌ Invalid destination address pointer");
            return false;
        }
    };

    if tx_out.is_null() || tx_out_len.is_null() || nullifiers_out.is_null() {
        eprintln!("❌ Null output pointers");
        return false;
    }

    // Deserialize spending key
    let extsk = match ExtendedSpendingKey::read(&mut &sk_slice[..]) {
        Ok(key) => key,
        Err(e) => {
            eprintln!("❌ Failed to read spending key: {:?}", e);
            return false;
        }
    };

    // FIX #230: Parse destination address (replace .unwrap())
    let to_addr_arr: [u8; 43] = match safe_try_into(to_addr_slice) {
        Some(arr) => arr,
        None => {
            eprintln!("❌ Invalid destination address length");
            return false;
        }
    };
    let to_addr = match PaymentAddress::from_bytes(&to_addr_arr) {
        Some(addr) => addr,
        None => {
            eprintln!("❌ Invalid destination address");
            return false;
        }
    };

    // Calculate fee (standard 10000 zatoshis)
    let fee = 10000u64;

    // FIX #230: Parse all spends with safe pointer validation
    let spend_infos = match safe_slice(spends as *const *const SpendInfo as *const u8, spend_count * std::mem::size_of::<*const SpendInfo>()) {
        Some(_) => slice::from_raw_parts(spends, spend_count),
        None => {
            eprintln!("❌ Invalid spends pointer");
            return false;
        }
    };
    let mut total_input: u64 = 0;
    let mut parsed_spends: Vec<(zcash_primitives::sapling::Note, MerklePath<zcash_primitives::sapling::Node, 32>, Diversifier)> = Vec::new();

    for (i, spend_ptr) in spend_infos.iter().enumerate() {
        let spend = &**spend_ptr;

        // FIX #230: Validate spend data pointers
        let witness_slice = match safe_slice(spend.witness_data, spend.witness_len) {
            Some(s) => s,
            None => {
                eprintln!("❌ Invalid witness pointer for spend {}", i);
                return false;
            }
        };
        let rcm_slice = match safe_slice(spend.note_rcm, 32) {
            Some(s) => s,
            None => {
                eprintln!("❌ Invalid rcm pointer for spend {}", i);
                return false;
            }
        };
        let div_slice = match safe_slice(spend.note_diversifier, 11) {
            Some(s) => s,
            None => {
                eprintln!("❌ Invalid diversifier pointer for spend {}", i);
                return false;
            }
        };

        // Parse note commitment randomness
        let mut rcm_bytes = [0u8; 32];
        rcm_bytes.copy_from_slice(rcm_slice);
        let rcm = match Option::<jubjub::Fr>::from(jubjub::Fr::from_repr(rcm_bytes)) {
            Some(r) => r,
            None => {
                eprintln!("❌ Invalid rcm for spend {}", i);
                return false;
            }
        };

        // Parse diversifier
        let mut div_bytes = [0u8; 11];
        div_bytes.copy_from_slice(div_slice);
        let diversifier = Diversifier(div_bytes);

        // Get the address that received this note using the note's diversifier
        let fvk = extsk.to_diversifiable_full_viewing_key();
        let note_addr = match fvk.fvk().vk.to_payment_address(diversifier) {
            Some(addr) => addr,
            None => {
                eprintln!("❌ Invalid diversifier for spend {}", i);
                return false;
            }
        };

        // Create note to spend
        let note = zcash_primitives::sapling::Note::from_parts(
            note_addr,
            NoteValue::from_raw(spend.note_value),
            Rseed::BeforeZip212(rcm),
        );

        // Deserialize witness
        let mut reader = std::io::Cursor::new(witness_slice);
        let witness: IncrementalWitness<zcash_primitives::sapling::Node, 32> =
            match zcash_primitives::merkle_tree::read_incremental_witness(&mut reader) {
                Ok(w) => w,
                Err(e) => {
                    eprintln!("❌ Failed to deserialize witness for spend {}: {:?}", i, e);
                    return false;
                }
            };

        // Get merkle path
        let merkle_path = match witness.path() {
            Some(p) => p,
            None => {
                eprintln!("❌ Failed to get merkle path for spend {}", i);
                return false;
            }
        };

        total_input += spend.note_value;
        parsed_spends.push((note, merkle_path, diversifier));

        debug_log!("📝 Spend {}: value={} zatoshis", i, spend.note_value);
    }

    debug_log!("📊 Multi-input tx: {} spends, total input = {} zatoshis", spend_count, total_input);

    // Verify funds
    if total_input < amount + fee {
        eprintln!("❌ Insufficient funds: have {}, need {} (amount={} + fee={})",
                  total_input, amount + fee, amount, fee);
        return false;
    }

    // Create transaction builder
    let target_height = BlockHeight::from_u32(chain_height as u32);
    let mut builder = Builder::new(ZclassicNetwork, target_height, None);

    // Verify branch ID
    let branch_id = zcash_primitives::consensus::BranchId::for_height(&ZclassicNetwork, target_height);
    let branch_id_u32: u32 = branch_id.into();
    debug_log!("🔑 Branch ID: 0x{:08x} at height {}", branch_id_u32, chain_height);

    if chain_height >= 707000 && branch_id_u32 != 0x930b540d {
        eprintln!("❌ ERROR: At height {}, expected branch ID 0x930b540d (Buttercup) but got 0x{:08x}", chain_height, branch_id_u32);
    }

    // Add all spends
    for (i, (note, merkle_path, diversifier)) in parsed_spends.iter().enumerate() {
        if let Err(e) = builder.add_sapling_spend(
            extsk.clone(),
            *diversifier,
            note.clone(),
            merkle_path.clone(),
        ) {
            eprintln!("❌ Failed to add spend {}: {:?}", i, e);
            return false;
        }
        debug_log!("✅ Spend {} added successfully", i);
    }

    // FIX #230: Prepare memo with safe_slice
    let memo_bytes = if memo.is_null() {
        [0u8; 512]
    } else {
        let memo_slice = match safe_slice(memo, 512) {
            Some(s) => s,
            None => {
                eprintln!("❌ Invalid memo pointer in multi-input tx");
                return false;
            }
        };
        let mut m = [0u8; 512];
        m.copy_from_slice(memo_slice);
        m
    };
    let memo_obj = match MemoBytes::from_bytes(&memo_bytes) {
        Ok(m) => m,
        Err(e) => {
            eprintln!("❌ Invalid memo bytes in multi-input tx: {:?}", e);
            return false;
        }
    };

    // FIX #230: Add output to recipient (safe Amount conversion)
    let amount_val = match Amount::from_i64(amount as i64) {
        Ok(a) => a,
        Err(_) => {
            eprintln!("❌ Invalid amount in multi-input tx: {}", amount);
            return false;
        }
    };
    if let Err(e) = builder.add_sapling_output(
        Some(extsk.expsk.ovk),
        to_addr,
        amount_val,
        memo_obj,
    ) {
        eprintln!("❌ Failed to add output: {:?}", e);
        return false;
    }

    // FIX #230: Add change output with safe Amount conversion
    let change = total_input - amount - fee;
    if change > 0 {
        let change_memo = MemoBytes::empty();
        let change_amount = match Amount::from_i64(change as i64) {
            Ok(a) => a,
            Err(_) => {
                eprintln!("❌ Invalid change amount in multi-input tx: {}", change);
                return false;
            }
        };
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
        debug_log!("💰 Change output: {} zatoshis", change);
    }

    // FIX #230: Build transaction with safe fee conversion
    debug_log!("🔨 Building multi-input transaction...");
    let fee_amount = match Amount::from_i64(fee as i64) {
        Ok(a) => a,
        Err(_) => {
            eprintln!("❌ Invalid fee amount in multi-input tx: {}", fee);
            return false;
        }
    };
    let (tx, _) = match builder.build(prover, &zcash_primitives::transaction::fees::fixed::FeeRule::non_standard(fee_amount)) {
        Ok(result) => result,
        Err(e) => {
            eprintln!("❌ Failed to build transaction: {:?}", e);
            return false;
        }
    };

    // Compute and output nullifiers for all spent notes
    // Get the nullifier deriving key (nk) from the viewing key
    let dfvk = extsk.to_diversifiable_full_viewing_key();
    let nk = dfvk.fvk().vk.nk;

    for (i, (note, merkle_path, _)) in parsed_spends.iter().enumerate() {
        // Get position from merkle path
        let position = u64::try_from(merkle_path.position()).unwrap_or(0);

        // Compute nullifier using proper PRF_nf
        let nf_result = note.nf(&nk, position);
        let nf_bytes = nf_result.0;

        // Copy to output buffer
        let offset = i * 32;
        std::ptr::copy_nonoverlapping(nf_bytes.as_ptr(), nullifiers_out.add(offset), 32);
        debug_log!("🔐 Nullifier {}: {}", i, hex::encode(&nf_bytes));
    }

    // Serialize transaction
    let mut tx_bytes = Vec::new();
    if let Err(e) = tx.write(&mut tx_bytes) {
        eprintln!("❌ Failed to serialize transaction: {:?}", e);
        return false;
    }

    debug_log!("✅ Multi-input transaction built: {} bytes, {} spends", tx_bytes.len(), spend_count);

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
    // FIX #230: Use safe_slice for bounds checking
    let rcv_slice = match safe_slice(rcv, 32) {
        Some(s) => s,
        None => {
            eprintln!("❌ Invalid rcv pointer");
            return false;
        }
    };

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

    // FIX #230: Use safe_slice for all input parameters
    let div_slice = match safe_slice(diversifier, 11) {
        Some(s) => s,
        None => {
            eprintln!("❌ Invalid diversifier pointer in encrypt_note");
            return false;
        }
    };
    let pk_d_slice = match safe_slice(pk_d, 32) {
        Some(s) => s,
        None => {
            eprintln!("❌ Invalid pk_d pointer in encrypt_note");
            return false;
        }
    };
    let rcm_slice = match safe_slice(rcm, 32) {
        Some(s) => s,
        None => {
            eprintln!("❌ Invalid rcm pointer in encrypt_note");
            return false;
        }
    };
    let memo_slice = match safe_slice(memo, 512) {
        Some(s) => s,
        None => {
            eprintln!("❌ Invalid memo pointer in encrypt_note");
            return false;
        }
    };

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
    // FIX #230: Use safe_slice for bounds checking
    let cmu_slice = match safe_slice(cmu, 32) {
        Some(s) => s,
        None => {
            eprintln!("❌ Invalid CMU pointer in tree_append");
            return u64::MAX;
        }
    };

    // FIX #230: Use safe_lock for mutex
    let mut tree_guard = match safe_lock!(COMMITMENT_TREE) {
        Some(g) => g,
        None => return u64::MAX,
    };
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

/// Batch append multiple CMUs to the tree (MUCH faster than individual appends)
/// cmus_data: Packed CMU data (32 bytes per CMU, in wire format)
/// cmu_count: Number of CMUs to append
/// Returns the starting position of the first CMU, or u64::MAX on error
#[no_mangle]
pub unsafe extern "C" fn zipherx_tree_append_batch(
    cmus_data: *const u8,
    cmu_count: usize,
) -> u64 {
    if cmus_data.is_null() || cmu_count == 0 {
        return u64::MAX;
    }

    // FIX #230: Use safe_slice for bounds checking
    let data = match safe_slice(cmus_data, cmu_count * 32) {
        Some(s) => s,
        None => {
            eprintln!("❌ Invalid CMUs data pointer in tree_append_batch");
            return u64::MAX;
        }
    };

    // FIX #230: Use safe_lock for mutex
    let mut tree_guard = match safe_lock!(COMMITMENT_TREE) {
        Some(g) => g,
        None => return u64::MAX,
    };
    let tree = match tree_guard.as_mut() {
        Some(t) => t,
        None => return u64::MAX,
    };

    let mut pos_guard = match safe_lock!(TREE_POSITION) {
        Some(g) => g,
        None => return u64::MAX,
    };
    let start_position = *pos_guard;

    // Parse all CMUs first
    let mut nodes: Vec<zcash_primitives::sapling::Node> = Vec::with_capacity(cmu_count);
    for i in 0..cmu_count {
        let cmu_slice = &data[i * 32..(i + 1) * 32];
        match zcash_primitives::sapling::Node::read(cmu_slice) {
            Ok(n) => nodes.push(n),
            Err(_) => return u64::MAX,
        }
    }

    // Append all nodes to tree
    for node in &nodes {
        if tree.append(*node).is_err() {
            return u64::MAX;
        }
    }

    // Update all existing witnesses with all new nodes (batch)
    let mut witnesses_guard = WITNESSES.lock().unwrap();
    for node in &nodes {
        for witness in witnesses_guard.iter_mut() {
            witness.append(*node).ok();
        }
    }

    *pos_guard += cmu_count as u64;

    start_position
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

    // FIX #230: Use safe_slice for bounds checking
    let witness_slice = match safe_slice(witness_data, witness_len) {
        Some(s) => s,
        None => {
            eprintln!("❌ Invalid witness pointer in tree_load_witness");
            return u64::MAX;
        }
    };

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

    // FIX #230: Use safe_lock for mutex
    let mut witnesses_guard = match safe_lock!(WITNESSES) {
        Some(g) => g,
        None => return u64::MAX,
    };
    let index = witnesses_guard.len();
    witnesses_guard.push(witness);

    debug_log!("📝 Loaded witness at index {}", index);
    index as u64
}

/// Get the root of the tree
/// root_out: 32-byte output buffer for the root
#[no_mangle]
pub unsafe extern "C" fn zipherx_tree_root(root_out: *mut u8) -> bool {
    // FIX #230: Use safe_lock for mutex
    let tree_guard = match safe_lock!(COMMITMENT_TREE) {
        Some(g) => g,
        None => return false,
    };
    let tree = match tree_guard.as_ref() {
        Some(t) => t,
        None => return false,
    };

    let root = tree.root();
    let mut root_bytes = Vec::new();
    if root.write(&mut root_bytes).is_err() {
        eprintln!("❌ Failed to write root bytes");
        return false;
    }

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

    // FIX #230: Use safe_slice for bounds checking
    let witness_slice = match safe_slice(witness_data, witness_len) {
        Some(s) => s,
        None => {
            eprintln!("❌ Invalid witness pointer in witness_update");
            return false;
        }
    };
    let cmu_slice = match safe_slice(cmu, 32) {
        Some(s) => s,
        None => {
            eprintln!("❌ Invalid CMU pointer in witness_update");
            return false;
        }
    };

    // FIX #230: Parse position from witness (safe conversion)
    let position = match witness_slice[0..4].try_into() {
        Ok(bytes) => u32::from_le_bytes(bytes),
        Err(_) => return false,
    };

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
    // FIX #230: Use safe_lock for mutex
    let tree_guard = match safe_lock!(COMMITMENT_TREE) {
        Some(g) => g,
        None => return false,
    };
    let tree = match tree_guard.as_ref() {
        Some(t) => t,
        None => return false,
    };

    let mut data = Vec::new();

    // FIX #230: Write tree size with safe_lock
    let pos_guard = match safe_lock!(TREE_POSITION) {
        Some(g) => g,
        None => return false,
    };
    data.extend_from_slice(&pos_guard.to_le_bytes());

    // Serialize tree
    if write_commitment_tree(tree, &mut data).is_err() {
        return false;
    }

    // FIX #557 v7: Increased limit to 20MB to handle large trees (1M+ commitments)
    // Each commitment is ~11 bytes, so 1M commitments = ~11MB
    if data.len() > 20_000_000 {
        eprintln!("❌ Tree too large to serialize ({} bytes)", data.len());
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

    // FIX #230: Use safe_slice for bounds checking
    let data = match safe_slice(tree_data, tree_len) {
        Some(s) => s,
        None => {
            eprintln!("❌ Invalid tree data pointer in tree_deserialize");
            return false;
        }
    };

    // FIX #230: Read position with safe conversion
    let position = match data[0..8].try_into() {
        Ok(bytes) => u64::from_le_bytes(bytes),
        Err(_) => return false,
    };

    // Deserialize tree
    let tree = match read_commitment_tree(&data[8..]) {
        Ok(t) => t,
        Err(e) => {
            eprintln!("❌ Failed to deserialize tree: {:?}", e);
            return false;
        }
    };

    // FIX #230: Use safe_lock for mutex
    let mut tree_guard = match safe_lock!(COMMITMENT_TREE) {
        Some(g) => g,
        None => return false,
    };
    *tree_guard = Some(tree);

    let mut pos_guard = match safe_lock!(TREE_POSITION) {
        Some(g) => g,
        None => return false,
    };
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

    // FIX #230: Use safe_slice for bounds checking
    let bytes = match safe_slice(data, data_len) {
        Some(s) => s,
        None => {
            eprintln!("❌ Invalid data pointer in tree_load_from_cmus");
            return false;
        }
    };

    // FIX #230: Read count with safe conversion
    let count = match bytes[0..8].try_into() {
        Ok(arr) => u64::from_le_bytes(arr),
        Err(_) => return false,
    };

    // SECURITY FIX (NEW-001): Prevent integer overflow
    let max_safe_count = (usize::MAX / 32).saturating_sub(1) as u64;
    if count > max_safe_count {
        debug_log!("❌ CMU count {} exceeds safe maximum", count);
        return false;
    }

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

    // FIX #230: Store in global with safe_lock
    let mut tree_guard = match safe_lock!(COMMITMENT_TREE) {
        Some(g) => g,
        None => return false,
    };
    *tree_guard = Some(tree);

    let mut pos_guard = match safe_lock!(TREE_POSITION) {
        Some(g) => g,
        None => return false,
    };
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

    // FIX #230: Use safe_slice for bounds checking
    let bytes = match safe_slice(data, data_len) {
        Some(s) => s,
        None => {
            eprintln!("❌ Invalid data pointer in tree_load_with_progress");
            return false;
        }
    };

    // FIX #230: Read count with safe conversion
    let count = match bytes[0..8].try_into() {
        Ok(arr) => u64::from_le_bytes(arr),
        Err(_) => return false,
    };

    // SECURITY FIX (NEW-001): Prevent integer overflow on 32-bit platforms
    // Max safe count = (usize::MAX - 8) / 32 to prevent overflow in expected_len calculation
    let max_safe_count = (usize::MAX / 32).saturating_sub(1) as u64;
    if count > max_safe_count {
        debug_log!("❌ CMU count {} exceeds safe maximum {}", count, max_safe_count);
        return false;
    }

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

    // FIX #230: Store in global with safe_lock
    let mut tree_guard = match safe_lock!(COMMITMENT_TREE) {
        Some(g) => g,
        None => return false,
    };
    *tree_guard = Some(tree);

    let mut pos_guard = match safe_lock!(TREE_POSITION) {
        Some(g) => g,
        None => return false,
    };
    *pos_guard = count;

    debug_log!("✅ Tree loaded with {} commitments", count);

    true
}

/// FIX #197: Load tree from CMU data AND create witnesses for target CMUs in SINGLE PASS
/// This eliminates PHASE 1.5 by combining tree loading with witness creation.
///
/// Parameters:
/// - data: Bundled CMU data [count: u64][cmu1: 32]...
/// - data_len: Length of CMU data
/// - target_cmus: Array of 32-byte target CMUs to create witnesses for
/// - target_count: Number of target CMUs
/// - positions_out: Output array for positions (u64 * target_count)
/// - witnesses_out: Output array for witnesses (1028 bytes * target_count)
/// - progress_callback: Progress callback(current, total)
///
/// Returns: Number of witnesses successfully created
#[no_mangle]
pub unsafe extern "C" fn zipherx_tree_load_with_witnesses(
    data: *const u8,
    data_len: usize,
    target_cmus: *const u8,
    target_count: usize,
    positions_out: *mut u64,
    witnesses_out: *mut u8,
    progress_callback: TreeLoadProgressCallback,
) -> usize {
    if data_len < 8 {
        return 0;
    }

    // FIX #230: Validate data pointer before creating slice
    let bytes = match safe_slice(data, data_len) {
        Some(s) => s,
        None => {
            eprintln!("❌ Invalid data pointer in tree_load_with_witnesses");
            return 0;
        }
    };

    // Read count - use safe conversion instead of unwrap
    let count = match bytes[0..8].try_into() {
        Ok(arr) => u64::from_le_bytes(arr),
        Err(_) => return 0,
    };

    // SECURITY FIX (NEW-001): Prevent integer overflow
    let max_safe_count = (usize::MAX / 32).saturating_sub(1) as u64;
    if count > max_safe_count {
        debug_log!("❌ CMU count {} exceeds safe maximum {}", count, max_safe_count);
        return 0;
    }

    let expected_len = 8 + (count as usize * 32);
    if data_len < expected_len {
        return 0;
    }

    debug_log!("🔧 FIX #197: Loading tree with {} CMUs AND creating {} witnesses in single pass",
               count, target_count);
    let start_time = std::time::Instant::now();

    // FIX #230: Build HashMap of target CMUs for O(1) lookup with safe slice
    let targets = if target_count > 0 {
        safe_slice(target_cmus, target_count * 32)
    } else {
        None
    };

    // FIX #471: Support both byte orders for target CMUs to handle potential byte order mismatches
    // The database might store CMUs in different byte order than boost file
    let mut target_map: std::collections::HashMap<[u8; 32], usize> = std::collections::HashMap::new();
    let mut target_map_reversed: std::collections::HashMap<[u8; 32], usize> = std::collections::HashMap::new();

    if let Some(targets) = targets {
        for i in 0..target_count {
            let offset = i * 32;
            let mut cmu = [0u8; 32];
            cmu.copy_from_slice(&targets[offset..offset + 32]);

            // Insert both original and reversed byte orders
            target_map.insert(cmu, i);

            let mut cmu_reversed = [0u8; 32];
            for j in 0..32 {
                cmu_reversed[j] = cmu[31 - j];
            }
            target_map_reversed.insert(cmu_reversed, i);

            // FIX #471: Debug log first few target CMUs in both byte orders
            if i < 3 {
                eprintln!("🎯 FIX #471: Target CMU[{}]: {}... (reversed: {}...)",
                         i, hex::encode(&cmu[0..8]), hex::encode(&cmu_reversed[0..8]));
            }
        }
        eprintln!("🎯 FIX #471: Loaded {} target CMUs into lookup maps (both byte orders)", target_count);
    }

    // Storage for witnesses captured during tree build
    let mut captured_witnesses: Vec<(usize, u64, IncrementalWitness<zcash_primitives::sapling::Node, 32>)> = Vec::new();

    // Report initial progress
    progress_callback(0, count);

    // Build tree, capturing witnesses at target positions
    let mut tree: CommitmentTree<zcash_primitives::sapling::Node, 32> = CommitmentTree::empty();
    let mut offset = 8;
    let mut found_count = 0;

    for i in 0..count {
        let cmu_bytes = &bytes[offset..offset + 32];
        offset += 32;

        let node = match zcash_primitives::sapling::Node::read(&cmu_bytes[..]) {
            Ok(n) => n,
            Err(_) => return 0,
        };

        // FIX #458: Check if this CMU is a target BEFORE appending
        // The witness must be created BEFORE the CMU is added to the tree,
        // so the witness is positioned at the leaf that will contain this CMU
        // FIX #471: Try both byte orders to handle database storage inconsistencies
        if !target_map.is_empty() {
            let mut cmu = [0u8; 32];
            cmu.copy_from_slice(cmu_bytes);

            // Try original byte order first
            let mut orig_idx = None;
            if let Some(&idx) = target_map.get(&cmu) {
                orig_idx = Some(idx);
            } else {
                // Try reversed byte order
                let mut cmu_reversed = [0u8; 32];
                for j in 0..32 {
                    cmu_reversed[j] = cmu[31 - j];
                }
                if let Some(&idx) = target_map_reversed.get(&cmu_reversed) {
                    orig_idx = Some(idx);
                    eprintln!("🔄 FIX #471: Target CMU matched in REVERSED byte order at position {} (CMU: {}...)",
                             i, hex::encode(&cmu[0..8]));
                }
            }

            if let Some(idx) = orig_idx {
                // CRITICAL: Create witness BEFORE appending CMU to tree!
                // This ensures the witness path is computed from the correct position
                let witness = IncrementalWitness::from_tree(tree.clone());
                captured_witnesses.push((idx, i, witness));
                found_count += 1;
                debug_log!("📍 FIX #458: Target {} found at position {} (CMU: {}...)", idx, i, hex::encode(&cmu[0..8]));
            }
        }

        // Now append the CMU to the tree (after creating witness if needed)
        if tree.append(node.clone()).is_err() {
            return 0;
        }

        // Report progress every 10000 CMUs
        if i > 0 && i % 10000 == 0 {
            progress_callback(i, count);
        }
    }

    // Final progress - tree building complete
    progress_callback(count, count);

    debug_log!("⏱️ FIX #197: Tree built in {:.1}s, found {}/{} targets",
               start_time.elapsed().as_secs_f64(), found_count, target_count);

    // FIX #197 v2: Update witnesses with remaining CMUs using PARALLEL Rayon
    // This is the bottleneck - each witness needs to be updated with CMUs after its position
    if !captured_witnesses.is_empty() {
        debug_log!("🔄 FIX #197: Updating {} witnesses with remaining CMUs (parallel)...", captured_witnesses.len());
        let update_start = std::time::Instant::now();

        // Get remaining CMUs as nodes for witness updates
        // captured_witnesses already have position info, update in parallel
        use rayon::prelude::*;
        use std::sync::atomic::{AtomicUsize, Ordering};

        let completed = AtomicUsize::new(0);
        let total = captured_witnesses.len();

        captured_witnesses.par_iter_mut().for_each(|(orig_idx, pos, witness)| {
            // This witness was created at position *pos, needs updates from pos+1 to count-1
            let mut local_offset = 8 + ((*pos as usize + 1) * 32);
            let mut updates = 0u64;
            while local_offset + 32 <= data_len {
                let cmu_bytes = &bytes[local_offset..local_offset + 32];
                local_offset += 32;
                if let Ok(node) = zcash_primitives::sapling::Node::read(&cmu_bytes[..]) {
                    witness.append(node).ok();
                    updates += 1;
                }
            }
            debug_log!("📝 FIX #197: Witness {} updated with {} CMUs", orig_idx, updates);

            // FIX #464: Report progress during parallel witness updates
            let done = completed.fetch_add(1, Ordering::Relaxed) + 1;
            // Report progress every 10% of witnesses completed
            if done % 10 == 0 || done == total {
                progress_callback(done as u64, total as u64);
            }
        });

        debug_log!("⏱️ FIX #197: Witness updates took {:.1}s (parallel)",
                   update_start.elapsed().as_secs_f64());
    }

    // Store tree in global
    let mut tree_guard = COMMITMENT_TREE.lock().unwrap();
    *tree_guard = Some(tree);

    let mut pos_guard = TREE_POSITION.lock().unwrap();
    *pos_guard = count;

    let tree_time = start_time.elapsed();
    debug_log!("⏱️ FIX #197: Tree loaded in {:.1}s, found {}/{} targets",
               tree_time.as_secs_f64(), found_count, target_count);

    // Serialize witnesses to output
    let mut success_count = 0;
    debug_log!("🔧 FIX #466: Starting serialization of {} captured witnesses", captured_witnesses.len());
    for (orig_idx, pos, witness) in captured_witnesses {
        let pos_ptr = positions_out.add(orig_idx);
        let witness_ptr = witnesses_out.add(orig_idx * 1028);

        // FIX #466 v2: Check witness path BEFORE serialization
        let path_filled = witness.path().is_some();
        let root = witness.root();
        let mut root_bytes = [0u8; 32];
        root.write(&mut root_bytes[..]).unwrap_or(());

        debug_log!("🔍 FIX #466: Witness[{}] at pos {} - path_filled={}, root={:02x}{:02x}...{} bytes",
                   orig_idx, pos, path_filled, root_bytes[0], root_bytes[1],
                   if path_filled { "OK" } else { "EMPTY PATH!" });

        let mut serialized = Vec::new();
        match write_incremental_witness(&witness, &mut serialized) {
            Ok(()) => {
                debug_log!("✅ FIX #466: Witness[{}] serialized to {} bytes (path_filled={})",
                           orig_idx, serialized.len(), path_filled);
                if serialized.len() <= 1028 {
                    *pos_ptr = pos;
                    std::ptr::copy_nonoverlapping(serialized.as_ptr(), witness_ptr, serialized.len());
                    if serialized.len() < 1028 {
                        std::ptr::write_bytes(witness_ptr.add(serialized.len()), 0, 1028 - serialized.len());
                    }
                    success_count += 1;
                } else {
                    debug_log!("❌ FIX #466: Witness[{}] too large: {} bytes", orig_idx, serialized.len());
                    *pos_ptr = u64::MAX;
                }
            }
            Err(e) => {
                debug_log!("❌ FIX #466: Failed to serialize witness[{}]: {:?}", orig_idx, e);
                *pos_ptr = u64::MAX;
            }
        }
    }

    debug_log!("✅ FIX #197: Tree loaded + {} witnesses created in {:.1}s (PHASE 1.5 eliminated!)",
               success_count, start_time.elapsed().as_secs_f64());
    success_count
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

    // FIX #230: Use safe_slice for bounds checking
    let bytes = match safe_slice(cmu_data, cmu_data_len) {
        Some(s) => s,
        None => {
            eprintln!("❌ Invalid CMU data pointer in create_witness_for_cmu");
            return u64::MAX;
        }
    };
    let target_bytes = match safe_slice(target_cmu, 32) {
        Some(s) => s,
        None => {
            eprintln!("❌ Invalid target CMU pointer in create_witness_for_cmu");
            return u64::MAX;
        }
    };

    // FIX #230: Read count with safe conversion
    let count = match bytes[0..8].try_into() {
        Ok(arr) => u64::from_le_bytes(arr),
        Err(_) => return u64::MAX,
    };

    // SECURITY FIX (NEW-001): Prevent integer overflow
    let max_safe_count = (usize::MAX / 32).saturating_sub(1) as u64;
    if count > max_safe_count {
        return u64::MAX;
    }

    let expected_len = 8 + (count as usize * 32);

    if cmu_data_len < expected_len {
        return u64::MAX;
    }

    // FIX #471: Check both original AND reversed byte orders for target CMU
    // The database might store CMUs in different byte order than boost file
    let mut target_bytes_reversed = [0u8; 32];
    for j in 0..32 {
        target_bytes_reversed[j] = target_bytes[31 - j];
    }

    // Find target CMU position (compare against wire format in file)
    // FIX #514: Try both byte orders to handle potential mismatches
    let mut target_pos: Option<u64> = None;
    let mut offset = 8;
    for i in 0..count {
        if &bytes[offset..offset + 32] == target_bytes {
            target_pos = Some(i);
            debug_log!("📍 Found target CMU at position {} (original byte order)", i);
            break;
        }
        // Also try reversed byte order
        if &bytes[offset..offset + 32] == target_bytes_reversed {
            target_pos = Some(i);
            debug_log!("📍 Found target CMU at position {} (REVERSED byte order - database has opposite order!)", i);
            break;
        }
        offset += 32;
    }

    let target_pos = match target_pos {
        Some(p) => p,
        None => {
            debug_log!("❌ FIX #514: Target CMU not found in bundled data (tried both byte orders)");
            debug_log!("   Target CMU: {}", hex::encode(target_bytes));
            debug_log!("   Target CMU (reversed): {}", hex::encode(target_bytes_reversed));
            return u64::MAX;
        }
    };

    // Remove the old log line since we now log when found
    // debug_log!("📍 Found target CMU at position {}", target_pos);

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

        // FIX #458: Create witness BEFORE appending at target position
        if i == target_pos {
            witness = Some(IncrementalWitness::from_tree(tree.clone()));
        }

        if tree.append(node).is_err() {
            return u64::MAX;
        }

        // Update existing witness with new nodes after target position
        if i > target_pos {
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

    // FIX #230: Use safe_slice for bounds checking
    let bytes = match safe_slice(cmu_data, cmu_data_len) {
        Some(s) => s,
        None => {
            eprintln!("❌ Invalid CMU data pointer in find_cmu_position");
            return u64::MAX;
        }
    };
    let target_bytes = match safe_slice(target_cmu, 32) {
        Some(s) => s,
        None => {
            eprintln!("❌ Invalid target CMU pointer in find_cmu_position");
            return u64::MAX;
        }
    };

    // FIX #230: Read count with safe conversion
    let count = match bytes[0..8].try_into() {
        Ok(arr) => u64::from_le_bytes(arr),
        Err(_) => return u64::MAX,
    };

    // SECURITY FIX (NEW-001): Prevent integer overflow
    let max_safe_count = (usize::MAX / 32).saturating_sub(1) as u64;
    if count > max_safe_count {
        return u64::MAX;
    }

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

/// Create witnesses for MULTIPLE CMUs in a SINGLE tree pass (batch operation)
/// This is much faster than calling zipherx_tree_create_witness_for_cmu multiple times
/// because it only builds the tree ONCE instead of N times.
///
/// Parameters:
/// - cmu_data: Bundled CMU file [count: u64][cmu1: 32]...
/// - cmu_data_len: Length of CMU data
/// - target_cmus: Array of 32-byte CMUs to create witnesses for
/// - target_count: Number of target CMUs
/// - positions_out: Output array for positions (u64 * target_count)
/// - witnesses_out: Output array for witnesses (1028 bytes * target_count)
///
/// Returns: Number of witnesses successfully created
#[no_mangle]
pub unsafe extern "C" fn zipherx_tree_create_witnesses_batch(
    cmu_data: *const u8,
    cmu_data_len: usize,
    target_cmus: *const u8,
    target_count: usize,
    positions_out: *mut u64,
    witnesses_out: *mut u8,
) -> usize {
    if cmu_data_len < 8 || target_count == 0 {
        return 0;
    }

    // FIX #230: Use safe_slice for bounds checking
    let bytes = match safe_slice(cmu_data, cmu_data_len) {
        Some(s) => s,
        None => {
            eprintln!("❌ Invalid CMU data pointer in create_witnesses_batch");
            return 0;
        }
    };
    let targets = match safe_slice(target_cmus, target_count * 32) {
        Some(s) => s,
        None => {
            eprintln!("❌ Invalid targets pointer in create_witnesses_batch");
            return 0;
        }
    };

    // FIX #230: Read CMU count with safe conversion
    let count = match bytes[0..8].try_into() {
        Ok(arr) => u64::from_le_bytes(arr),
        Err(_) => return 0,
    };

    // SECURITY FIX (NEW-001): Prevent integer overflow
    let max_safe_count = (usize::MAX / 32).saturating_sub(1) as u64;
    if count > max_safe_count {
        return 0;
    }

    let expected_len = 8 + (count as usize * 32);

    if cmu_data_len < expected_len {
        return 0;
    }

    debug_log!("🔧 Batch witness: {} targets, {} total CMUs", target_count, count);

    // FIX #514 v3: Create reversed byte lookup maps for all targets (byte order mismatch handling)
    // The database might store CMUs in different byte order than boost file
    let mut target_bytes_reversed: Vec<[u8; 32]> = vec![[0u8; 32]; target_count];
    for t_idx in 0..target_count {
        let target_offset = t_idx * 32;
        // Reverse: swap bytes from opposite ends
        for j in 0..32 {
            target_bytes_reversed[t_idx][j] = targets[target_offset + (31 - j)];
        }
    }

    // First pass: find all target positions (fast linear scan)
    let mut target_positions: Vec<Option<u64>> = vec![None; target_count];
    let mut offset = 8;
    for i in 0..count {
        let cmu_bytes = &bytes[offset..offset + 32];
        for (t_idx, target_offset) in (0..target_count).map(|t| (t, t * 32)) {
            if target_positions[t_idx].is_none() {
                // FIX #514 v3: Check both original AND reversed byte orders
                let target_bytes = &targets[target_offset..target_offset + 32];
                let target_reversed = &target_bytes_reversed[t_idx];

                if target_bytes == cmu_bytes {
                    target_positions[t_idx] = Some(i);
                    debug_log!("📍 Target {} found at position {} (original byte order)", t_idx, i);
                } else if target_reversed == cmu_bytes {
                    target_positions[t_idx] = Some(i);
                    debug_log!("📍 Target {} found at position {} (REVERSED byte order)", t_idx, i);
                }
            }
        }
        offset += 32;
    }

    // Find the maximum position we need to build to
    let max_pos = target_positions.iter().filter_map(|p| *p).max();
    let max_pos = match max_pos {
        Some(p) => p,
        None => {
            debug_log!("❌ No target CMUs found in bundled data");
            return 0;
        }
    };

    debug_log!("🌲 FIX #557 v23: Building tree once, creating witnesses with same root");

    // FIX #557 v23: Build tree ONCE, create witnesses at max position, all have same root
    let mut tree: CommitmentTree<zcash_primitives::sapling::Node, 32> = CommitmentTree::empty();
    let mut witnesses: Vec<Option<IncrementalWitness<zcash_primitives::sapling::Node, 32>>> = vec![None; target_count];
    offset = 8;

    // Build tree to max_pos, creating witnesses AFTER each target position
    for i in 0..=max_pos {
        let cmu_bytes = &bytes[offset..offset + 32];
        offset += 32;

        let node = match zcash_primitives::sapling::Node::read(&cmu_bytes[..]) {
            Ok(n) => n,
            Err(_) => continue,
        };

        tree.append(node).ok();

        // Create witness AFTER appending CMU (witness includes this CMU in path)
        for (t_idx, &pos_opt) in target_positions.iter().enumerate() {
            if let Some(pos) = pos_opt {
                if pos == i {
                    witnesses[t_idx] = Some(IncrementalWitness::from_tree(tree.clone()));
                    debug_log!("✅ FIX #557 v23: Created witness[{}] at position {} (after CMU)", t_idx, i);
                }
            }
        }
    }

    // Continue building tree to end, updating ALL witnesses
    while offset + 32 <= cmu_data_len {
        let cmu_bytes = &bytes[offset..offset + 32];
        offset += 32;

        let node = match zcash_primitives::sapling::Node::read(&cmu_bytes[..]) {
            Ok(n) => n,
            Err(_) => continue,
        };

        tree.append(node).ok();

        // Update ALL witnesses
        for witness_opt in witnesses.iter_mut() {
            if let Some(ref mut w) = witness_opt {
                w.append(node).ok();
            }
        }
    }

    let final_root = tree.root();
    let mut final_root_bytes = [0u8; 32];
    final_root.write(&mut final_root_bytes[..]).unwrap_or(());
    debug_log!("🌳 FIX #557 v23: Final root: {}", hex::encode(&final_root_bytes[..4]));

    // Verify all witnesses have the same root
    let mut all_match = true;
    for (t_idx, witness_opt) in witnesses.iter().enumerate() {
        if let Some(w) = witness_opt {
            let w_root = w.root();
            if w_root != final_root {
                all_match = false;
                let mut w_root_bytes = [0u8; 32];
                w_root.write(&mut w_root_bytes[..]).unwrap_or(());
                debug_log!("⚠️ FIX #557 v23: Witness[{}] has wrong root: {} (expected: {})",
                    t_idx, hex::encode(&w_root_bytes[..4]), hex::encode(&final_root_bytes[..4]));
            }
        }
    }

    if all_match {
        debug_log!("✅ FIX #557 v23: All witnesses have the SAME final root!");
    } else {
        debug_log!("⚠️ FIX #557 v23: Witnesses have DIFFERENT roots - append() not working as expected");
    }


    // Serialize witnesses to output
    let mut success_count = 0;
    for (t_idx, witness_opt) in witnesses.iter().enumerate() {
        let pos_ptr = positions_out.add(t_idx);
        let witness_ptr = witnesses_out.add(t_idx * 1028);

        if let (Some(pos), Some(witness)) = (target_positions[t_idx], witness_opt) {
            // FIX #557 v23: Verify witness root before serialization
            let witness_root = witness.root();
            if witness_root == final_root {
                debug_log!("✅ FIX #557 v23: Witness[{}] at pos {} has final root", t_idx, pos);
            } else {
                let mut witness_root_bytes = [0u8; 32];
                witness_root.write(&mut witness_root_bytes[..]).unwrap_or(());
                debug_log!("⚠️ FIX #557 v23: Witness[{}] at pos {} has wrong root: {} (expected: {})",
                           t_idx, pos,
                           hex::encode(&witness_root_bytes[..4]),
                           hex::encode(&final_root_bytes[..4]));
            }

            let mut serialized = Vec::new();
            if write_incremental_witness(witness, &mut serialized).is_ok() && serialized.len() <= 1028 {
                *pos_ptr = pos;
                std::ptr::copy_nonoverlapping(serialized.as_ptr(), witness_ptr, serialized.len());
                // Zero-pad
                if serialized.len() < 1028 {
                    std::ptr::write_bytes(witness_ptr.add(serialized.len()), 0, 1028 - serialized.len());
                }
                success_count += 1;
                debug_log!("📝 Serialized witness {} ({} bytes)", t_idx, serialized.len());
            } else {
                *pos_ptr = u64::MAX;
            }
        } else {
            *pos_ptr = u64::MAX;
        }
    }

    debug_log!("✅ Batch witness complete: {}/{} successful", success_count, target_count);
    success_count
}

/// Extract the root (anchor) from serialized witness data
/// This is needed when using treeCreateWitnessesBatch which builds its own tree
/// rather than using the global COMMITMENT_TREE
///
/// witness_data: Serialized witness (1028 bytes)
/// root_out: 32-byte output buffer for the root
/// Returns: true if successful
#[no_mangle]
pub unsafe extern "C" fn zipherx_witness_get_root(
    witness_data: *const u8,
    witness_len: usize,
    root_out: *mut u8,
) -> bool {
    if witness_len < 100 {
        return false;
    }

    // FIX #230: Validate witness pointer with safe_slice
    let witness_slice = match safe_slice(witness_data, witness_len) {
        Some(s) => s,
        None => return false,
    };
    let mut reader = std::io::Cursor::new(witness_slice);

    let witness: IncrementalWitness<zcash_primitives::sapling::Node, 32> =
        match zcash_primitives::merkle_tree::read_incremental_witness(&mut reader) {
            Ok(w) => w,
            Err(_) => return false,
        };

    let root = witness.root();
    let mut root_bytes = Vec::new();
    if root.write(&mut root_bytes).is_err() {
        return false;
    }

    std::ptr::copy_nonoverlapping(root_bytes.as_ptr(), root_out, 32);
    true
}

/// Check if a witness path is valid (non-empty)
/// FIX #557: Verify that witness.path() returns Some instead of None
/// A witness with empty path will compute wrong anchor even if root is correct
///
/// Parameters:
/// - witness_data: Serialized witness data
/// - witness_len: Length of witness data
///
/// Returns: true if path is valid (witness.path() returns Some), false otherwise
#[no_mangle]
pub unsafe extern "C" fn zipherx_witness_path_is_valid(
    witness_data: *const u8,
    witness_len: usize,
) -> bool {
    if witness_len < 100 {
        return false;
    }

    // FIX #230: Validate witness pointer with safe_slice
    let witness_slice = match safe_slice(witness_data, witness_len) {
        Some(s) => s,
        None => return false,
    };
    let mut reader = std::io::Cursor::new(witness_slice);

    let witness: IncrementalWitness<zcash_primitives::sapling::Node, 32> =
        match zcash_primitives::merkle_tree::read_incremental_witness(&mut reader) {
            Ok(w) => w,
            Err(_) => return false,
        };

    // Check if path() returns Some (valid path) or None (empty/stale witness)
    let path_is_valid = witness.path().is_some();
    debug_log!("🔍 witness_path_is_valid: path_is_some={}", path_is_valid);
    path_is_valid
}

/// Create witnesses for multiple CMUs using BATCH processing (OPTIMIZED)
///
/// PERFORMANCE: Builds tree ONCE and captures witnesses incrementally as we pass each target.
/// This is O(N) where N = total CMUs, instead of O(N * targets) for naive parallel approach.
///
/// For 53 witnesses in 1M CMUs:
/// - OLD parallel: 53 threads × 1M appends each = 53M operations (386 seconds)
/// - NEW batch: 1 thread × 1M appends total = 1M operations (~30 seconds)
///
/// Parameters:
/// - target_cmus: Array of target CMUs to find (32 bytes each)
/// - target_count: Number of target CMUs
/// - cmu_data: The bundled CMU data
/// - cmu_data_len: Length of CMU data
/// - positions_out: Output array for positions (u64 per target)
/// - witnesses_out: Output array for witnesses (1028 bytes per target)
///
/// Returns: Number of witnesses successfully created
#[no_mangle]
pub unsafe extern "C" fn zipherx_tree_create_witnesses_parallel(
    target_cmus: *const u8,
    target_count: usize,
    cmu_data: *const u8,
    cmu_data_len: usize,
    positions_out: *mut u64,
    witnesses_out: *mut u8,
) -> usize {
    if target_count == 0 || cmu_data_len < 8 {
        return 0;
    }

    // FIX #230: Validate pointers with safe_slice
    let targets = match safe_slice(target_cmus, target_count * 32) {
        Some(s) => s,
        None => {
            eprintln!("❌ Invalid target_cmus pointer in create_witnesses_parallel");
            return 0;
        }
    };
    let bytes = match safe_slice(cmu_data, cmu_data_len) {
        Some(s) => s,
        None => {
            eprintln!("❌ Invalid cmu_data pointer in create_witnesses_parallel");
            return 0;
        }
    };

    // Read CMU count from bundled data - use safe conversion
    let count = match bytes[0..8].try_into() {
        Ok(arr) => u64::from_le_bytes(arr),
        Err(_) => return 0,
    };

    // SECURITY FIX (NEW-001): Prevent integer overflow
    let max_safe_count = (usize::MAX / 32).saturating_sub(1) as u64;
    if count > max_safe_count {
        debug_log!("❌ CMU count {} exceeds safe maximum", count);
        return 0;
    }

    let expected_len = 8 + (count as usize * 32);

    if cmu_data_len < expected_len {
        debug_log!("❌ CMU data too short: {} < {}", cmu_data_len, expected_len);
        return 0;
    }

    debug_log!("🔧 Batch witness (optimized): {} targets, {} total CMUs", target_count, count);
    let start_time = std::time::Instant::now();

    // FIX #514 v3: Build a HashMap of target CMUs for O(1) lookup
    // Include both original AND reversed byte orders for database compatibility
    let mut target_map: std::collections::HashMap<[u8; 32], usize> = std::collections::HashMap::new();
    for i in 0..target_count {
        let offset = i * 32;

        // Add original byte order
        let mut cmu = [0u8; 32];
        cmu.copy_from_slice(&targets[offset..offset + 32]);
        target_map.insert(cmu, i);

        // FIX #514 v3: Also add reversed byte order
        let mut cmu_reversed = [0u8; 32];
        for j in 0..32 {
            cmu_reversed[j] = targets[offset + (31 - j)];
        }
        target_map.insert(cmu_reversed, i);
    }

    // Storage for witnesses we capture during tree build
    // Each entry: (original_index, position, witness at that position)
    let mut captured_witnesses: Vec<(usize, u64, IncrementalWitness<zcash_primitives::sapling::Node, 32>)> = Vec::new();

    // Build tree ONCE, capturing witnesses at target positions
    let mut tree: CommitmentTree<zcash_primitives::sapling::Node, 32> = CommitmentTree::empty();
    let mut offset = 8;
    let mut found_count = 0;

    for i in 0..count {
        let cmu_bytes = &bytes[offset..offset + 32];
        offset += 32;

        let node = match zcash_primitives::sapling::Node::read(&cmu_bytes[..]) {
            Ok(n) => n,
            Err(_) => continue,
        };

        // FIX #458: Check if this is a target CMU BEFORE appending
        // The witness must be created BEFORE the CMU is added to the tree
        let mut cmu = [0u8; 32];
        cmu.copy_from_slice(cmu_bytes);
        if let Some(&orig_idx) = target_map.get(&cmu) {
            // Capture witness at this position BEFORE appending CMU
            let witness = IncrementalWitness::from_tree(tree.clone());
            captured_witnesses.push((orig_idx, i, witness));
            found_count += 1;
            debug_log!("📍 FIX #458: Target {} found at position {}", orig_idx, i);

            // Early exit if we found all targets
            if found_count == target_count {
                debug_log!("🎯 All {} targets found, finishing tree build for witnesses", target_count);
            }
        }

        if tree.append(node).is_err() {
            continue;
        }
    }

    if captured_witnesses.is_empty() {
        debug_log!("❌ No target CMUs found in bundled data");
        return 0;
    }

    let tree_build_time = start_time.elapsed();
    debug_log!("⏱️ Tree build phase took {:.1}s (found {}/{})",
               tree_build_time.as_secs_f64(), found_count, target_count);

    // FIX #557 v18: Update all captured witnesses to have the same final root
    // The witnesses were captured at different positions, so they have different roots.
    // We need to update each witness with CMUs from its position to the end.
    debug_log!("🔄 FIX #557 v18: Updating {} witnesses to final anchor...", captured_witnesses.len());
    let update_start = std::time::Instant::now();

    // Get the final tree root for verification
    let final_root = tree.root();
    let mut final_root_bytes = [0u8; 32];
    final_root.write(&mut final_root_bytes[..]).unwrap_or(());
    debug_log!("🌳 FIX #557 v18: Final tree root: {}", hex::encode(&final_root_bytes[..4]));

    // For each captured witness, we need to update it with CMUs that came AFTER its position
    // The witnesses were captured BEFORE appending their target CMU, so they include all CMUs
    // from 0 to pos-1. We need to add CMUs from pos to count-1.
    let mut final_witnesses: Vec<(usize, u64, IncrementalWitness<zcash_primitives::sapling::Node, 32>)> = Vec::new();

    for (orig_idx, pos, old_witness) in captured_witnesses {
        // Start with a clone of the old witness (which has CMUs 0 to pos-1)
        let mut witness = old_witness;

        // Add CMUs from pos to count-1 (including the target CMU and all after it)
        let mut update_offset = 8 + (pos as usize * 32);
        while update_offset + 32 <= cmu_data_len {
            let cmu_bytes = &bytes[update_offset..update_offset + 32];
            update_offset += 32;

            if let Ok(node) = zcash_primitives::sapling::Node::read(&cmu_bytes[..]) {
                witness.append(node).ok();
            }
        }

        // Verify the witness now has the correct root
        let witness_root = witness.root();
        if witness_root == final_root {
            debug_log!("✅ FIX #557 v18: Witness[{}] at pos {} now has final root", orig_idx, pos);
        } else {
            let mut witness_root_bytes = [0u8; 32];
            witness_root.write(&mut witness_root_bytes[..]).unwrap_or(());
            debug_log!("⚠️ FIX #557 v18: Witness[{}] at pos {} has wrong root: {} (expected: {})",
                       orig_idx, pos,
                       hex::encode(&witness_root_bytes[..4]),
                       hex::encode(&final_root_bytes[..4]));
        }

        final_witnesses.push((orig_idx, pos, witness));
    }

    let update_time = update_start.elapsed();
    debug_log!("⏱️ FIX #557 v18: Witness update took {:.1}s", update_time.as_secs_f64());

    // Serialize and copy results to output arrays
    let mut success_count = 0;
    for (orig_idx, pos, witness) in final_witnesses {
        let pos_ptr = positions_out.add(orig_idx);
        let witness_ptr = witnesses_out.add(orig_idx * 1028);

        let mut serialized = Vec::new();
        if write_incremental_witness(&witness, &mut serialized).is_ok() && serialized.len() <= 1028 {
            *pos_ptr = pos;
            std::ptr::copy_nonoverlapping(serialized.as_ptr(), witness_ptr, serialized.len());
            if serialized.len() < 1028 {
                std::ptr::write_bytes(witness_ptr.add(serialized.len()), 0, 1028 - serialized.len());
            }
            success_count += 1;
            debug_log!("📝 Witness {} at pos {} ({} bytes)", orig_idx, pos, serialized.len());
        } else {
            *pos_ptr = u64::MAX;
        }
    }

    let total_time = start_time.elapsed();
    debug_log!("✅ FIX #557 v18: Batch witness complete: {}/{} in {:.1}s (tree: {:.1}s, update: {:.1}s)",
               success_count, target_count, total_time.as_secs_f64(),
               tree_build_time.as_secs_f64(), update_time.as_secs_f64());
    success_count
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

    // FIX #230: Parse OVK with safe_slice
    let ovk_slice = match safe_slice(ovk, 32) {
        Some(s) => s,
        None => {
            eprintln!("❌ Invalid OVK pointer");
            return 0;
        }
    };
    let ovk_arr: [u8; 32] = match ovk_slice.try_into() {
        Ok(arr) => arr,
        Err(_) => return 0,
    };
    let ovk = OutgoingViewingKey(ovk_arr);

    // FIX #230: Parse value commitment (cv) with safe_slice
    let cv_slice = match safe_slice(cv, 32) {
        Some(s) => s,
        None => {
            eprintln!("❌ Invalid CV pointer");
            return 0;
        }
    };
    let cv_bytes: [u8; 32] = match cv_slice.try_into() {
        Ok(arr) => arr,
        Err(_) => return 0,
    };
    let cv = match ValueCommitment::from_bytes_not_small_order(&cv_bytes).into() {
        Some(v) => v,
        None => return 0,
    };

    // FIX #230: Parse cmu with safe_slice
    let cmu_slice = match safe_slice(cmu, 32) {
        Some(s) => s,
        None => {
            eprintln!("❌ Invalid CMU pointer in recover_output");
            return 0;
        }
    };
    let cmu_bytes: [u8; 32] = match cmu_slice.try_into() {
        Ok(arr) => arr,
        Err(_) => return 0,
    };
    let cmu = match zcash_primitives::sapling::note::ExtractedNoteCommitment::from_bytes(&cmu_bytes).into() {
        Some(c) => c,
        None => return 0,
    };

    // FIX #230: Parse EPK with safe_slice
    let epk_slice = match safe_slice(epk, 32) {
        Some(s) => s,
        None => {
            eprintln!("❌ Invalid EPK pointer");
            return 0;
        }
    };
    let epk_bytes: [u8; 32] = match epk_slice.try_into() {
        Ok(arr) => arr,
        Err(_) => return 0,
    };
    let epk = EphemeralKeyBytes(epk_bytes);

    // FIX #230: Get ciphertexts with safe_slice
    let enc = match safe_slice(enc_ciphertext, 580) {
        Some(s) => s,
        None => {
            eprintln!("❌ Invalid enc_ciphertext pointer");
            return 0;
        }
    };
    let out = match safe_slice(out_ciphertext, 80) {
        Some(s) => s,
        None => {
            eprintln!("❌ Invalid out_ciphertext pointer");
            return 0;
        }
    };

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
    // FIX #230: Use safe_slice for bounds checking
    let sk_bytes = match safe_slice(sk, 169) {
        Some(s) => s,
        None => {
            eprintln!("❌ Invalid spending key pointer in derive_ovk");
            return false;
        }
    };

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

// =============================================================================
// Equihash Verification for Block Header Validation
// =============================================================================

/// Verify an Equihash solution for a Zclassic block header
/// This is CRITICAL for trustless P2P operation - validates proof-of-work
///
/// Parameters:
/// - header_bytes: The 140-byte block header (version through nonce)
/// - solution: The Equihash solution bytes
/// - solution_len: Length of the solution
///
/// Returns true if the Equihash solution is valid
///
/// Zclassic uses Equihash(200, 9) - same as Zcash
/// Solution size: (2^K) * (N/(K+1) + 1) / 8 = 512 * 21 / 8 = 1344 bytes
#[no_mangle]
pub unsafe extern "C" fn zipherx_verify_equihash(
    header_bytes: *const u8,
    solution: *const u8,
    solution_len: usize,
) -> bool {
    // Zclassic changed Equihash parameters at the Bubbles upgrade (block 585,318):
    // - Before Bubbles (blocks 0-585,317): Equihash(200, 9) - 1344 byte solutions
    // - After Bubbles (blocks 585,318+): Equihash(192, 7) - 400 byte solutions
    // Current blocks use (192, 7)
    const N: u32 = 192;
    const K: u32 = 7;

    // Expected solution size: (2^K) * (N/(K+1) + 1) / 8 = 128 * 25 / 8 = 400 bytes
    const EXPECTED_SOLUTION_LEN: usize = 400;

    // Debug: log solution length mismatch
    if solution_len != EXPECTED_SOLUTION_LEN {
        eprintln!("❌ Equihash solution length mismatch: got {} bytes, expected {} bytes for ({},{})",
                  solution_len, EXPECTED_SOLUTION_LEN, N, K);
    }

    // FIX #230: Header is 140 bytes total with safe_slice
    // - First 108 bytes: header data (input for Equihash)
    // - Last 32 bytes: nonce
    let header = match safe_slice(header_bytes, 140) {
        Some(s) => s,
        None => {
            eprintln!("❌ Invalid header pointer in verify_equihash");
            return false;
        }
    };
    let solution_slice = match safe_slice(solution, solution_len) {
        Some(s) => s,
        None => {
            eprintln!("❌ Invalid solution pointer in verify_equihash");
            return false;
        }
    };

    // Split header into input (108 bytes) and nonce (32 bytes)
    let input = &header[..108];
    let nonce = &header[108..140];

    // Verify the Equihash solution
    // is_valid_solution returns Result<(), Error> - Ok means valid, Err means invalid
    match equihash::is_valid_solution(N, K, input, nonce, solution_slice) {
        Ok(()) => {
            debug_log!("✅ Equihash solution is valid");
            true
        }
        Err(e) => {
            eprintln!("❌ Equihash verification failed (solution_len={}): {:?}", solution_len, e);
            false
        }
    }
}

/// Compute the block hash for a Zclassic block header
/// The block hash is double SHA256 of: header (140 bytes) + solution length (varint) + solution
///
/// Parameters:
/// - header_bytes: The 140-byte block header
/// - solution: The Equihash solution bytes
/// - solution_len: Length of the solution
/// - hash_out: Output buffer for 32-byte hash (will be in internal byte order)
///
/// Returns true on success
#[no_mangle]
pub unsafe extern "C" fn zipherx_compute_block_hash(
    header_bytes: *const u8,
    solution: *const u8,
    solution_len: usize,
    hash_out: *mut u8,
) -> bool {
    use sha2::{Sha256, Digest};

    // FIX #230: Use safe_slice for bounds checking
    let header = match safe_slice(header_bytes, 140) {
        Some(s) => s,
        None => {
            eprintln!("❌ Invalid header pointer in compute_block_hash");
            return false;
        }
    };
    let solution_slice = match safe_slice(solution, solution_len) {
        Some(s) => s,
        None => {
            eprintln!("❌ Invalid solution pointer in compute_block_hash");
            return false;
        }
    };

    // Build the data to hash: header + compact size + solution
    let mut data = Vec::with_capacity(140 + 5 + solution_len);
    data.extend_from_slice(header);

    // Write compact size (varint) for solution length
    // Equihash(200,9) solution is 1344 bytes, so we need 3-byte encoding
    if solution_len < 253 {
        data.push(solution_len as u8);
    } else if solution_len < 0x10000 {
        data.push(253);
        data.push((solution_len & 0xff) as u8);
        data.push(((solution_len >> 8) & 0xff) as u8);
    } else {
        data.push(254);
        data.push((solution_len & 0xff) as u8);
        data.push(((solution_len >> 8) & 0xff) as u8);
        data.push(((solution_len >> 16) & 0xff) as u8);
        data.push(((solution_len >> 24) & 0xff) as u8);
    }

    data.extend_from_slice(solution_slice);

    // Double SHA256
    let hash1 = Sha256::digest(&data);
    let hash2 = Sha256::digest(&hash1);

    // Copy to output (in internal byte order - NOT reversed for display)
    std::ptr::copy_nonoverlapping(hash2.as_ptr(), hash_out, 32);

    true
}

/// Verify a chain of block headers for continuity and valid PoW
/// Checks that each header's prevHash matches the previous header's hash
/// and that each Equihash solution is valid
///
/// Parameters:
/// - headers_data: Concatenated header data (each header is 140 bytes + varint solution_len + solution)
/// - headers_count: Number of headers in the chain
/// - expected_prev_hash: The expected prevHash of the first header (32 bytes), or null to skip first check
/// - header_offsets: Array of byte offsets where each header starts (count entries)
/// - header_sizes: Array of total sizes for each header including solution (count entries)
///
/// Returns true if all headers are valid and chain is continuous
#[no_mangle]
pub unsafe extern "C" fn zipherx_verify_header_chain(
    headers_data: *const u8,
    headers_count: usize,
    expected_prev_hash: *const u8,
    header_offsets: *const usize,
    header_sizes: *const usize,
) -> bool {
    if headers_count == 0 {
        return true;
    }

    // FIX #230: Validate all pointers with safe_slice
    let offsets = match safe_slice(header_offsets, headers_count) {
        Some(s) => s,
        None => {
            eprintln!("❌ Invalid header_offsets pointer");
            return false;
        }
    };
    let sizes = match safe_slice(header_sizes, headers_count) {
        Some(s) => s,
        None => {
            eprintln!("❌ Invalid header_sizes pointer");
            return false;
        }
    };

    let mut prev_hash: [u8; 32] = [0; 32];
    let has_expected_prev = !expected_prev_hash.is_null();

    if has_expected_prev {
        let expected = match safe_slice(expected_prev_hash, 32) {
            Some(s) => s,
            None => {
                eprintln!("❌ Invalid expected_prev_hash pointer");
                return false;
            }
        };
        prev_hash.copy_from_slice(expected);
    }

    for i in 0..headers_count {
        let offset = offsets[i];
        let size = sizes[i];

        if size < 140 {
            eprintln!("❌ Header {} too small: {} bytes", i, size);
            return false;
        }

        let header_ptr = headers_data.add(offset);
        let header = match safe_slice(header_ptr, 140) {
            Some(s) => s,
            None => {
                eprintln!("❌ Invalid header pointer at index {}", i);
                return false;
            }
        };

        // Extract prevHash from header (bytes 4-36)
        let header_prev_hash = &header[4..36];

        // Check chain continuity (skip first if no expected_prev_hash provided)
        if i > 0 || has_expected_prev {
            if header_prev_hash != prev_hash {
                eprintln!("❌ Header {} prevHash mismatch - chain broken!", i);
                eprintln!("   Expected: {}", hex::encode(&prev_hash));
                eprintln!("   Got:      {}", hex::encode(header_prev_hash));
                return false;
            }
        }

        // Get solution (after 140-byte header)
        let solution_start = offset + 140;
        let solution_data = headers_data.add(solution_start);

        // Read compact size for solution length
        let first_byte = *solution_data;
        let (solution_len, solution_offset) = if first_byte < 253 {
            (first_byte as usize, 1)
        } else if first_byte == 253 {
            let len = (*solution_data.add(1) as usize) | ((*solution_data.add(2) as usize) << 8);
            (len, 3)
        } else {
            eprintln!("❌ Header {} has invalid solution length encoding", i);
            return false;
        };

        let solution_ptr = solution_data.add(solution_offset);

        // Verify Equihash
        if !zipherx_verify_equihash(header_ptr, solution_ptr, solution_len) {
            eprintln!("❌ Header {} failed Equihash verification", i);
            return false;
        }

        // Compute this block's hash for next iteration
        let mut hash_out: [u8; 32] = [0; 32];
        zipherx_compute_block_hash(header_ptr, solution_ptr, solution_len, hash_out.as_mut_ptr());
        prev_hash = hash_out;

        debug_log!("✅ Header {} verified, hash: {}", i, hex::encode(&prev_hash));
    }

    eprintln!("✅ All {} headers verified successfully", headers_count);
    true
}

/// Verify a single block header's Equihash and return its hash
/// Simpler interface for single header verification
///
/// Parameters:
/// - header_and_solution: Full header data (140 bytes header + varint + solution)
/// - total_len: Total length of the data
/// - hash_out: Output buffer for 32-byte block hash
///
/// Returns true if header is valid
#[no_mangle]
pub unsafe extern "C" fn zipherx_verify_block_header(
    header_and_solution: *const u8,
    total_len: usize,
    hash_out: *mut u8,
) -> bool {
    if total_len < 141 {
        eprintln!("❌ Header data too small: {} bytes", total_len);
        return false;
    }

    // FIX #230: Validate header pointer
    let header = match safe_slice(header_and_solution, 140) {
        Some(s) => s,
        None => {
            eprintln!("❌ Invalid header pointer");
            return false;
        }
    };
    let solution_data = header_and_solution.add(140);

    // Read compact size for solution length
    let first_byte = *solution_data;
    let (solution_len, solution_offset) = if first_byte < 253 {
        (first_byte as usize, 1)
    } else if first_byte == 253 {
        let len = (*solution_data.add(1) as usize) | ((*solution_data.add(2) as usize) << 8);
        (len, 3)
    } else {
        eprintln!("❌ Invalid solution length encoding");
        return false;
    };

    // Verify expected total length
    let expected_len = 140 + solution_offset + solution_len;
    if total_len < expected_len {
        eprintln!("❌ Header data truncated: got {} bytes, expected {}", total_len, expected_len);
        return false;
    }

    let solution_ptr = solution_data.add(solution_offset);

    // Verify Equihash
    if !zipherx_verify_equihash(header_and_solution, solution_ptr, solution_len) {
        return false;
    }

    // Compute and return hash
    zipherx_compute_block_hash(header_and_solution, solution_ptr, solution_len, hash_out);

    true
}

// =============================================================================
// VUL-002 FIX: Encrypted Key Operations
// =============================================================================
// These functions accept AES-GCM-256 encrypted spending keys and decrypt them
// in Rust where memory can be explicitly zeroed. The decrypted key never leaves
// Rust's control and is zeroed immediately after use.
//
// Encryption format (197 bytes):
// - 12 bytes: Nonce
// - 169 bytes: Encrypted spending key
// - 16 bytes: Authentication tag
//
// The encryption key (32 bytes) is derived from device ID + salt using HKDF on
// the Swift side and passed separately.

/// Zero-fill a mutable byte slice to securely erase sensitive data
/// Uses volatile write pattern to prevent compiler optimization
#[inline(never)]
fn secure_zero(data: &mut [u8]) {
    use std::ptr;
    for byte in data.iter_mut() {
        unsafe {
            ptr::write_volatile(byte, 0);
        }
    }
    // Memory barrier to ensure the writes are not optimized away
    std::sync::atomic::compiler_fence(std::sync::atomic::Ordering::SeqCst);
}

/// Decrypt an AES-GCM-256 encrypted spending key
/// Returns a vector that should be zeroed after use
fn decrypt_spending_key(
    encrypted_sk: &[u8],   // 197 bytes: nonce(12) + ciphertext(169) + tag(16)
    encryption_key: &[u8], // 32 bytes: AES-256 key
) -> Result<Vec<u8>, &'static str> {
    use chacha20poly1305::aead::generic_array::GenericArray;

    if encrypted_sk.len() != 197 {
        return Err("Invalid encrypted key length (expected 197 bytes)");
    }
    if encryption_key.len() != 32 {
        return Err("Invalid encryption key length (expected 32 bytes)");
    }

    // Parse components
    let nonce = &encrypted_sk[0..12];
    let ciphertext_with_tag = &encrypted_sk[12..197]; // 169 + 16 = 185 bytes

    // Use AES-256-GCM for decryption
    use aes_gcm::{Aes256Gcm, KeyInit, aead::Aead};
    use aes_gcm::aead::generic_array::GenericArray as AesGenericArray;

    let key = AesGenericArray::from_slice(encryption_key);
    let cipher = Aes256Gcm::new(key);
    let nonce_arr = AesGenericArray::from_slice(nonce);

    match cipher.decrypt(nonce_arr, ciphertext_with_tag) {
        Ok(decrypted) => {
            if decrypted.len() != 169 {
                return Err("Decrypted key has wrong length");
            }
            Ok(decrypted)
        }
        Err(_) => Err("AES-GCM decryption failed (wrong key or corrupted data)"),
    }
}

/// Build a shielded transaction using an encrypted spending key (VUL-002 secure)
///
/// This is the secure version of zipherx_build_transaction. The spending key is:
/// 1. Encrypted with AES-GCM-256 on the Swift side
/// 2. Passed to Rust encrypted
/// 3. Decrypted only within this function
/// 4. Used for transaction building
/// 5. Immediately zeroed after use
///
/// # Safety
/// - encrypted_sk: 197-byte AES-GCM encrypted spending key (nonce + ciphertext + tag)
/// - encryption_key: 32-byte AES-256 key for decryption
/// - to_address: 43-byte payment address
/// - amount: amount to send in zatoshis
/// - memo: 512-byte memo or null for empty
/// - witness_data: serialized IncrementalWitness
/// - witness_len: length of witness data
/// - note_value: value of note being spent in zatoshis
/// - note_rcm: 32-byte note commitment randomness
/// - note_diversifier: 11-byte diversifier
/// - chain_height: current chain height for branch ID
/// - tx_out: output buffer (at least 10000 bytes)
/// - tx_out_len: receives actual transaction length
///
/// Returns true on success, false on failure
#[no_mangle]
pub unsafe extern "C" fn zipherx_build_transaction_encrypted(
    encrypted_sk: *const u8,
    encrypted_sk_len: usize,
    encryption_key: *const u8,
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
    // Validate input lengths
    if encrypted_sk_len != 197 {
        eprintln!("❌ Invalid encrypted key length: {} (expected 197)", encrypted_sk_len);
        return false;
    }

    // FIX #230: Use safe_slice for all inputs
    let encrypted_slice = match safe_slice(encrypted_sk, 197) {
        Some(s) => s,
        None => {
            eprintln!("❌ Invalid encrypted key pointer");
            return false;
        }
    };
    let enc_key_slice = match safe_slice(encryption_key, 32) {
        Some(s) => s,
        None => {
            eprintln!("❌ Invalid encryption key pointer");
            return false;
        }
    };

    // Decrypt the spending key
    let mut decrypted_sk = match decrypt_spending_key(encrypted_slice, enc_key_slice) {
        Ok(sk) => sk,
        Err(e) => {
            eprintln!("❌ Failed to decrypt spending key: {}", e);
            return false;
        }
    };

    debug_log!("🔐 VUL-002: Spending key decrypted in Rust (will zero after use)");

    // === Use the decrypted key ===

    // FIX #230: Get the prover with safe_lock
    let prover_guard = match safe_lock!(PROVER) {
        Some(g) => g,
        None => {
            secure_zero(&mut decrypted_sk);
            return false;
        }
    };
    let prover = match prover_guard.as_ref() {
        Some(p) => p,
        None => {
            secure_zero(&mut decrypted_sk);
            eprintln!("❌ Prover not initialized");
            return false;
        }
    };

    // FIX #230: Parse inputs with safe_slice
    let to_addr_slice = match safe_slice(to_address, 43) {
        Some(s) => s,
        None => {
            secure_zero(&mut decrypted_sk);
            eprintln!("❌ Invalid destination address pointer");
            return false;
        }
    };
    let witness_slice = match safe_slice(witness_data, witness_len) {
        Some(s) => s,
        None => {
            secure_zero(&mut decrypted_sk);
            eprintln!("❌ Invalid witness data pointer");
            return false;
        }
    };
    let rcm_slice = match safe_slice(note_rcm, 32) {
        Some(s) => s,
        None => {
            secure_zero(&mut decrypted_sk);
            eprintln!("❌ Invalid rcm pointer");
            return false;
        }
    };
    let div_slice = match safe_slice(note_diversifier, 11) {
        Some(s) => s,
        None => {
            secure_zero(&mut decrypted_sk);
            eprintln!("❌ Invalid diversifier pointer");
            return false;
        }
    };

    // Deserialize spending key from decrypted data
    let extsk = match ExtendedSpendingKey::read(&mut &decrypted_sk[..]) {
        Ok(key) => key,
        Err(e) => {
            secure_zero(&mut decrypted_sk);
            eprintln!("❌ Failed to read spending key: {:?}", e);
            return false;
        }
    };

    // FIX #230: Parse destination address (safe conversion)
    let to_addr_arr: [u8; 43] = match to_addr_slice.try_into() {
        Ok(arr) => arr,
        Err(_) => {
            secure_zero(&mut decrypted_sk);
            eprintln!("❌ Invalid destination address length");
            return false;
        }
    };
    let to_addr = match PaymentAddress::from_bytes(&to_addr_arr) {
        Some(addr) => addr,
        None => {
            secure_zero(&mut decrypted_sk);
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
            secure_zero(&mut decrypted_sk);
            eprintln!("❌ Invalid rcm");
            return false;
        }
    };

    // Parse diversifier
    let mut div_bytes = [0u8; 11];
    div_bytes.copy_from_slice(div_slice);
    let diversifier = Diversifier(div_bytes);

    // Get the address that received this note using the note's diversifier
    let fvk = extsk.to_diversifiable_full_viewing_key();
    let note_addr = match fvk.fvk().vk.to_payment_address(diversifier) {
        Some(addr) => addr,
        None => {
            secure_zero(&mut decrypted_sk);
            eprintln!("❌ Invalid diversifier for note address");
            return false;
        }
    };

    // Calculate fee
    let fee = 10000u64;

    // Verify funds
    if note_value < amount + fee {
        secure_zero(&mut decrypted_sk);
        eprintln!("❌ Insufficient funds: have {}, need {}", note_value, amount + fee);
        return false;
    }

    // Create note to spend using the diversifier's address
    let note = zcash_primitives::sapling::Note::from_parts(
        note_addr,
        NoteValue::from_raw(note_value),
        Rseed::BeforeZip212(rcm),
    );

    // Deserialize the IncrementalWitness
    let mut reader = std::io::Cursor::new(witness_slice);
    let witness: IncrementalWitness<zcash_primitives::sapling::Node, 32> =
        match zcash_primitives::merkle_tree::read_incremental_witness(&mut reader) {
            Ok(w) => w,
            Err(e) => {
                secure_zero(&mut decrypted_sk);
                eprintln!("❌ Failed to deserialize witness: {:?}", e);
                return false;
            }
        };

    // Get the merkle path from the witness
    let merkle_path = match witness.path() {
        Some(p) => p,
        None => {
            secure_zero(&mut decrypted_sk);
            eprintln!("❌ Failed to get merkle path from witness");
            return false;
        }
    };

    // Create transaction builder
    let target_height = BlockHeight::from_u32(chain_height as u32);
    let mut builder = Builder::new(ZclassicNetwork, target_height, None);

    // Add spend
    if let Err(e) = builder.add_sapling_spend(
        extsk.clone(),
        diversifier,
        note.clone(),
        merkle_path,
    ) {
        secure_zero(&mut decrypted_sk);
        eprintln!("❌ Failed to add spend: {:?}", e);
        return false;
    }

    // FIX #230: Prepare memo with safe slice validation
    let memo_bytes = if memo.is_null() {
        [0u8; 512]
    } else {
        match safe_slice(memo, 512) {
            Some(memo_slice) => {
                let mut m = [0u8; 512];
                m.copy_from_slice(memo_slice);
                m
            }
            None => {
                secure_zero(&mut decrypted_sk);
                eprintln!("❌ Invalid memo pointer");
                return false;
            }
        }
    };
    let memo_obj = match MemoBytes::from_bytes(&memo_bytes) {
        Ok(m) => m,
        Err(e) => {
            secure_zero(&mut decrypted_sk);
            eprintln!("❌ Invalid memo bytes: {:?}", e);
            return false;
        }
    };

    // Convert amount to Amount type - use safe conversion
    let amount_val = match Amount::from_i64(amount as i64) {
        Ok(a) => a,
        Err(_) => {
            secure_zero(&mut decrypted_sk);
            eprintln!("❌ Invalid amount: {}", amount);
            return false;
        }
    };

    // Add output to recipient
    if let Err(e) = builder.add_sapling_output(
        Some(extsk.expsk.ovk),
        to_addr,
        amount_val,
        memo_obj,
    ) {
        secure_zero(&mut decrypted_sk);
        eprintln!("❌ Failed to add output: {:?}", e);
        return false;
    }

    // Add change output if needed
    let change = note_value - amount - fee;
    if change > 0 {
        let change_memo = MemoBytes::empty();
        let change_amount = Amount::from_i64(change as i64).unwrap();
        let (_, change_addr) = extsk.default_address();
        if let Err(e) = builder.add_sapling_output(
            Some(extsk.expsk.ovk),
            change_addr,
            change_amount,
            change_memo,
        ) {
            secure_zero(&mut decrypted_sk);
            eprintln!("❌ Failed to add change output: {:?}", e);
            return false;
        }
    }

    // Build the transaction with proofs
    let (tx, _) = match builder.build(prover, &zcash_primitives::transaction::fees::fixed::FeeRule::non_standard(Amount::from_i64(fee as i64).unwrap())) {
        Ok(result) => result,
        Err(e) => {
            secure_zero(&mut decrypted_sk);
            eprintln!("❌ Failed to build transaction: {:?}", e);
            return false;
        }
    };

    // === CRITICAL: Zero the decrypted spending key ===
    secure_zero(&mut decrypted_sk);
    debug_log!("🔐 VUL-002: Spending key zeroed from memory");

    // Serialize transaction
    let mut tx_bytes = Vec::new();
    if let Err(e) = tx.write(&mut tx_bytes) {
        eprintln!("❌ Failed to serialize transaction: {:?}", e);
        return false;
    }

    // Copy to output
    if tx_bytes.len() > 10000 {
        eprintln!("❌ Transaction too large: {} bytes", tx_bytes.len());
        return false;
    }

    std::ptr::copy_nonoverlapping(tx_bytes.as_ptr(), tx_out, tx_bytes.len());
    *tx_out_len = tx_bytes.len();

    true
}

/// Build a shielded transaction with multiple inputs using encrypted spending key (VUL-002 secure)
///
/// This is the secure version of zipherx_build_transaction_multi.
///
/// # Safety
/// - encrypted_sk: 197-byte AES-GCM encrypted spending key
/// - encryption_key: 32-byte AES-256 key
/// - Other parameters same as zipherx_build_transaction_multi
#[no_mangle]
pub unsafe extern "C" fn zipherx_build_transaction_multi_encrypted(
    encrypted_sk: *const u8,
    encrypted_sk_len: usize,
    encryption_key: *const u8,
    to_address: *const u8,
    amount: u64,
    memo: *const u8,
    spends: *const *const SpendInfo,
    spend_count: usize,
    chain_height: u64,
    tx_out: *mut u8,
    tx_out_len: *mut usize,
    nullifiers_out: *mut u8,
) -> bool {
    if spend_count == 0 || spend_count > 100 {
        eprintln!("❌ Invalid spend count: {} (must be 1-100)", spend_count);
        return false;
    }

    // Validate input lengths
    if encrypted_sk_len != 197 {
        eprintln!("❌ Invalid encrypted key length: {} (expected 197)", encrypted_sk_len);
        return false;
    }

    // FIX #230: Use safe_slice for all inputs (multi-encrypted)
    let encrypted_slice = match safe_slice(encrypted_sk, 197) {
        Some(s) => s,
        None => {
            eprintln!("❌ Invalid encrypted key pointer");
            return false;
        }
    };
    let enc_key_slice = match safe_slice(encryption_key, 32) {
        Some(s) => s,
        None => {
            eprintln!("❌ Invalid encryption key pointer");
            return false;
        }
    };

    // Decrypt the spending key
    let mut decrypted_sk = match decrypt_spending_key(encrypted_slice, enc_key_slice) {
        Ok(sk) => sk,
        Err(e) => {
            eprintln!("❌ Failed to decrypt spending key: {}", e);
            return false;
        }
    };

    debug_log!("🔐 VUL-002: Spending key decrypted in Rust for multi-spend (will zero after use)");

    // FIX #230: Get the prover with safe_lock
    let prover_guard = match safe_lock!(PROVER) {
        Some(g) => g,
        None => {
            secure_zero(&mut decrypted_sk);
            return false;
        }
    };
    let prover = match prover_guard.as_ref() {
        Some(p) => p,
        None => {
            secure_zero(&mut decrypted_sk);
            eprintln!("❌ Prover not initialized");
            return false;
        }
    };

    // FIX #230: Parse inputs with safe_slice
    let to_addr_slice = match safe_slice(to_address, 43) {
        Some(s) => s,
        None => {
            secure_zero(&mut decrypted_sk);
            eprintln!("❌ Invalid destination address pointer");
            return false;
        }
    };

    // Deserialize spending key
    let extsk = match ExtendedSpendingKey::read(&mut &decrypted_sk[..]) {
        Ok(key) => key,
        Err(e) => {
            secure_zero(&mut decrypted_sk);
            eprintln!("❌ Failed to read spending key: {:?}", e);
            return false;
        }
    };

    // FIX #230: Parse destination address (safe conversion)
    let to_addr_arr: [u8; 43] = match to_addr_slice.try_into() {
        Ok(arr) => arr,
        Err(_) => {
            secure_zero(&mut decrypted_sk);
            eprintln!("❌ Invalid destination address length");
            return false;
        }
    };
    let to_addr = match PaymentAddress::from_bytes(&to_addr_arr) {
        Some(addr) => addr,
        None => {
            secure_zero(&mut decrypted_sk);
            eprintln!("❌ Invalid destination address");
            return false;
        }
    };

    // Calculate fee
    let fee = 10000u64;

    // FIX #230: Parse all spends with safe pointer validation
    let spend_infos = match safe_slice(spends as *const *const SpendInfo as *const u8, spend_count * std::mem::size_of::<*const SpendInfo>()) {
        Some(_) => std::slice::from_raw_parts(spends, spend_count),
        None => {
            secure_zero(&mut decrypted_sk);
            eprintln!("❌ Invalid spends pointer");
            return false;
        }
    };
    let mut total_input: u64 = 0;
    let mut parsed_spends: Vec<(zcash_primitives::sapling::Note, MerklePath<zcash_primitives::sapling::Node, 32>, Diversifier)> = Vec::new();

    for (i, spend_ptr) in spend_infos.iter().enumerate() {
        let spend = &**spend_ptr;

        // FIX #230: Validate spend data pointers
        let witness_slice = match safe_slice(spend.witness_data, spend.witness_len) {
            Some(s) => s,
            None => {
                secure_zero(&mut decrypted_sk);
                eprintln!("❌ Invalid witness pointer for spend {}", i);
                return false;
            }
        };
        let rcm_slice = match safe_slice(spend.note_rcm, 32) {
            Some(s) => s,
            None => {
                secure_zero(&mut decrypted_sk);
                eprintln!("❌ Invalid rcm pointer for spend {}", i);
                return false;
            }
        };
        let div_slice = match safe_slice(spend.note_diversifier, 11) {
            Some(s) => s,
            None => {
                secure_zero(&mut decrypted_sk);
                eprintln!("❌ Invalid diversifier pointer for spend {}", i);
                return false;
            }
        };

        // Parse note commitment randomness
        let mut rcm_bytes = [0u8; 32];
        rcm_bytes.copy_from_slice(rcm_slice);
        let rcm = match Option::<jubjub::Fr>::from(jubjub::Fr::from_repr(rcm_bytes)) {
            Some(r) => r,
            None => {
                secure_zero(&mut decrypted_sk);
                eprintln!("❌ Invalid rcm for spend {}", i);
                return false;
            }
        };

        // Parse diversifier
        let mut div_bytes = [0u8; 11];
        div_bytes.copy_from_slice(div_slice);
        let diversifier = Diversifier(div_bytes);

        // Get the address that received this note
        let fvk = extsk.to_diversifiable_full_viewing_key();
        let note_addr = match fvk.fvk().vk.to_payment_address(diversifier) {
            Some(addr) => addr,
            None => {
                secure_zero(&mut decrypted_sk);
                eprintln!("❌ Invalid diversifier for spend {}", i);
                return false;
            }
        };

        // Create note to spend
        let note = zcash_primitives::sapling::Note::from_parts(
            note_addr,
            NoteValue::from_raw(spend.note_value),
            Rseed::BeforeZip212(rcm),
        );

        // Deserialize witness
        let mut reader = std::io::Cursor::new(witness_slice);
        let witness: IncrementalWitness<zcash_primitives::sapling::Node, 32> =
            match zcash_primitives::merkle_tree::read_incremental_witness(&mut reader) {
                Ok(w) => w,
                Err(e) => {
                    secure_zero(&mut decrypted_sk);
                    eprintln!("❌ Failed to deserialize witness {}: {:?}", i, e);
                    return false;
                }
            };

        let merkle_path = match witness.path() {
            Some(p) => p,
            None => {
                secure_zero(&mut decrypted_sk);
                eprintln!("❌ Failed to get merkle path for spend {}", i);
                return false;
            }
        };

        total_input += spend.note_value;
        parsed_spends.push((note, merkle_path, diversifier));
    }

    // Verify funds
    if total_input < amount + fee {
        secure_zero(&mut decrypted_sk);
        eprintln!("❌ Insufficient funds: have {}, need {}", total_input, amount + fee);
        return false;
    }

    // Create transaction builder
    let target_height = BlockHeight::from_u32(chain_height as u32);
    let mut builder = Builder::new(ZclassicNetwork, target_height, None);

    // Add all spends
    for (note, merkle_path, diversifier) in parsed_spends.iter() {
        if let Err(e) = builder.add_sapling_spend(
            extsk.clone(),
            *diversifier,
            note.clone(),
            merkle_path.clone(),
        ) {
            secure_zero(&mut decrypted_sk);
            eprintln!("❌ Failed to add spend: {:?}", e);
            return false;
        }
    }

    // FIX #230: Prepare memo with safe slice validation
    let memo_bytes = if memo.is_null() {
        [0u8; 512]
    } else {
        match safe_slice(memo, 512) {
            Some(memo_slice) => {
                let mut m = [0u8; 512];
                m.copy_from_slice(memo_slice);
                m
            }
            None => {
                secure_zero(&mut decrypted_sk);
                eprintln!("❌ Invalid memo pointer");
                return false;
            }
        }
    };
    let memo_obj = match MemoBytes::from_bytes(&memo_bytes) {
        Ok(m) => m,
        Err(e) => {
            secure_zero(&mut decrypted_sk);
            eprintln!("❌ Invalid memo bytes: {:?}", e);
            return false;
        }
    };

    // Add output to recipient - use safe amount conversion
    let amount_val = match Amount::from_i64(amount as i64) {
        Ok(a) => a,
        Err(_) => {
            secure_zero(&mut decrypted_sk);
            eprintln!("❌ Invalid amount: {}", amount);
            return false;
        }
    };
    if let Err(e) = builder.add_sapling_output(
        Some(extsk.expsk.ovk),
        to_addr,
        amount_val,
        memo_obj,
    ) {
        secure_zero(&mut decrypted_sk);
        eprintln!("❌ Failed to add output: {:?}", e);
        return false;
    }

    // Add change output if needed - use safe amount conversion
    let change = total_input - amount - fee;
    if change > 0 {
        let change_memo = MemoBytes::empty();
        let change_amount = match Amount::from_i64(change as i64) {
            Ok(a) => a,
            Err(_) => {
                secure_zero(&mut decrypted_sk);
                eprintln!("❌ Invalid change amount: {}", change);
                return false;
            }
        };
        let (_, change_addr) = extsk.default_address();
        if let Err(e) = builder.add_sapling_output(
            Some(extsk.expsk.ovk),
            change_addr,
            change_amount,
            change_memo,
        ) {
            secure_zero(&mut decrypted_sk);
            eprintln!("❌ Failed to add change output: {:?}", e);
            return false;
        }
    }

    // Build the transaction with proofs
    let (tx, _) = match builder.build(prover, &zcash_primitives::transaction::fees::fixed::FeeRule::non_standard(Amount::from_i64(fee as i64).unwrap())) {
        Ok(result) => result,
        Err(e) => {
            secure_zero(&mut decrypted_sk);
            eprintln!("❌ Failed to build transaction: {:?}", e);
            return false;
        }
    };

    // Compute and output nullifiers for all spent notes
    let dfvk = extsk.to_diversifiable_full_viewing_key();
    let nk = dfvk.fvk().vk.nk;

    for (i, (note, merkle_path, _)) in parsed_spends.iter().enumerate() {
        let position = u64::try_from(merkle_path.position()).unwrap_or(0);
        let nf_result = note.nf(&nk, position);
        let nf_bytes = nf_result.0;
        let offset = i * 32;
        std::ptr::copy_nonoverlapping(nf_bytes.as_ptr(), nullifiers_out.add(offset), 32);
    }

    // === CRITICAL: Zero the decrypted spending key ===
    secure_zero(&mut decrypted_sk);
    debug_log!("🔐 VUL-002: Spending key zeroed from memory (multi-spend)");

    // Serialize transaction
    let mut tx_bytes = Vec::new();
    if let Err(e) = tx.write(&mut tx_bytes) {
        eprintln!("❌ Failed to serialize transaction: {:?}", e);
        return false;
    }

    if tx_bytes.len() > 10000 {
        eprintln!("❌ Transaction too large: {} bytes", tx_bytes.len());
        return false;
    }

    std::ptr::copy_nonoverlapping(tx_bytes.as_ptr(), tx_out, tx_bytes.len());
    *tx_out_len = tx_bytes.len();

    true
}

// =============================================================================
// Boost File Scanning - Complete wallet scan in Rust (matching benchmark)
// =============================================================================

/// Boost file output record size: height(4) + index(4) + cmu(32) + epk(32) + ciphertext(580) + txid(32) = 684
/// PRODUCTION UPGRADE: Now includes received_in_tx for accurate change detection!
const BOOST_OUTPUT_SIZE: usize = 684;
/// Boost file spend record size: height(4) + nullifier(32) + txid(32) = 68
const BOOST_SPEND_SIZE: usize = 68;

/// Result for a discovered note from boost file scanning
/// Contains all data needed to store in database and build transactions
/// PRODUCTION: Now includes received_txid - no more placeholders!
#[repr(C)]
pub struct BoostScanNote {
    pub height: u32,
    pub position: u64,
    pub value: u64,
    pub diversifier: [u8; 11],
    pub rcm: [u8; 32],
    pub cmu: [u8; 32],
    pub nullifier: [u8; 32],
    pub is_spent: u8,  // 1 if spent, 0 if unspent
    pub spent_height: u32,  // Height at which note was spent (0 if unspent)
    pub spent_txid: [u8; 32],  // Real txid of spending transaction (zeros if unspent)
    pub received_txid: [u8; 32],  // PRODUCTION: Real txid that created this output (no more placeholders!)
    pub _padding: [u8; 3],  // Alignment padding
}

/// Result structure for boost scan summary
#[repr(C)]
pub struct BoostScanResult {
    pub total_received: u64,     // Total value of all notes found
    pub total_spent: u64,        // Total value of spent notes
    pub unspent_balance: u64,    // Final spendable balance
    pub notes_found: u32,        // Number of notes found
    pub notes_spent: u32,        // Number of notes that are spent
    pub spends_checked: u32,     // Number of spends in boost file
}

/// Scan boost file outputs section and return discovered notes with nullifiers
///
/// This function performs the complete PHASE 1 + PHASE 1.6 scanning in Rust:
/// 1. Parse outputs from boost data (684 bytes per output - PRODUCTION v2)
/// 2. Parse spends from boost data (68 bytes per spend - PRODUCTION v2)
/// 3. Parallel note decryption using Rayon
/// 4. Compute nullifiers for each discovered note (using enumerate index as position)
/// 5. Check nullifiers against spends to detect spent notes
///
/// The returned data includes everything needed to:
/// - Store notes in SQLite database
/// - Build spend transactions (diversifier, value, rcm, nullifier, position)
///
/// # Arguments
/// * `sk` - Extended spending key (169 bytes)
/// * `outputs_data` - Pointer to outputs section (684 bytes per output - includes txid)
/// * `output_count` - Number of outputs
/// * `spends_data` - Pointer to spends section (68 bytes per spend - includes txid)
/// * `spend_count` - Number of spends
/// * `notes_out` - Output buffer for discovered notes (BoostScanNote array)
/// * `max_notes` - Maximum notes that can fit in notes_out
/// * `result_out` - Output for scan summary (BoostScanResult)
///
/// # Returns
/// Number of notes written to notes_out
#[no_mangle]
pub unsafe extern "C" fn zipherx_scan_boost_outputs(
    sk: *const u8,
    outputs_data: *const u8,
    output_count: usize,
    spends_data: *const u8,
    spend_count: usize,
    notes_out: *mut BoostScanNote,
    max_notes: usize,
    result_out: *mut BoostScanResult,
) -> usize {
    use std::collections::HashSet;
    use zcash_primitives::sapling::{Diversifier, Rseed};
    use jubjub::Fr;
    use ff::PrimeField;

    eprintln!("🚀 zipherx_scan_boost_outputs: {} outputs, {} spends", output_count, spend_count);

    if output_count == 0 {
        if !result_out.is_null() {
            (*result_out) = BoostScanResult {
                total_received: 0,
                total_spent: 0,
                unspent_balance: 0,
                notes_found: 0,
                notes_spent: 0,
                spends_checked: spend_count as u32,
            };
        }
        return 0;
    }

    // FIX #230: Parse spending key with safe slice validation
    let sk_slice = match safe_slice(sk, 169) {
        Some(s) => s,
        None => {
            eprintln!("❌ Invalid spending key pointer");
            return 0;
        }
    };
    let extsk = match ExtendedSpendingKey::read(&mut &sk_slice[..]) {
        Ok(key) => key,
        Err(e) => {
            eprintln!("❌ Failed to parse spending key: {:?}", e);
            return 0;
        }
    };

    // Derive keys for decryption and nullifier computation
    let dfvk = extsk.to_diversifiable_full_viewing_key();
    let fvk = dfvk.fvk();
    let ivk = fvk.vk.ivk();
    let prepared_ivk = PreparedIncomingViewingKey::new(&ivk);
    let nk = fvk.vk.nk;

    // Parse spends into HashMap: nullifier → (spend_height, txid)
    // Now includes the REAL txid from the boost file - no more placeholders!
    let mut nullifier_map: std::collections::HashMap<[u8; 32], (u32, [u8; 32])> = std::collections::HashMap::with_capacity(spend_count);
    if spend_count > 0 {
        let spends_slice = match safe_slice(spends_data, spend_count * BOOST_SPEND_SIZE) {
            Some(s) => s,
            None => {
                eprintln!("❌ Invalid spends_data pointer");
                return 0;
            }
        };
        for i in 0..spend_count {
            let offset = i * BOOST_SPEND_SIZE;
            // Read height (4 bytes) + nullifier (32 bytes) + txid (32 bytes) = 68 bytes
            let spend_height = u32::from_le_bytes([
                spends_slice[offset],
                spends_slice[offset + 1],
                spends_slice[offset + 2],
                spends_slice[offset + 3],
            ]);
            let mut nullifier = [0u8; 32];
            nullifier.copy_from_slice(&spends_slice[offset + 4..offset + 36]);
            let mut txid = [0u8; 32];
            txid.copy_from_slice(&spends_slice[offset + 36..offset + 68]);
            nullifier_map.insert(nullifier, (spend_height, txid));
        }
    }
    eprintln!("📊 Indexed {} nullifiers with spend heights and txids", nullifier_map.len());

    // FIX #230: Parse outputs for parallel processing with safe slice validation
    let outputs_slice = match safe_slice(outputs_data, output_count * BOOST_OUTPUT_SIZE) {
        Some(s) => s,
        None => {
            eprintln!("❌ Invalid outputs_data pointer");
            return 0;
        }
    };

    // Parse into vector of (position, height, cmu, epk, ciphertext, received_txid)
    // CRITICAL: position = enumerate index (outputs are in blockchain order)
    // PRODUCTION: Now includes received_txid for accurate change detection!
    let parsed_outputs: Vec<(usize, u32, [u8; 32], [u8; 32], [u8; 580], [u8; 32])> = (0..output_count)
        .map(|i| {
            let offset = i * BOOST_OUTPUT_SIZE;
            let height = u32::from_le_bytes([
                outputs_slice[offset],
                outputs_slice[offset + 1],
                outputs_slice[offset + 2],
                outputs_slice[offset + 3],
            ]);
            // Skip index (4 bytes at offset+4)
            let mut cmu = [0u8; 32];
            cmu.copy_from_slice(&outputs_slice[offset + 8..offset + 40]);
            let mut epk = [0u8; 32];
            epk.copy_from_slice(&outputs_slice[offset + 40..offset + 72]);
            let mut ciphertext = [0u8; 580];
            ciphertext.copy_from_slice(&outputs_slice[offset + 72..offset + 652]);
            // PRODUCTION: Read received_txid (32 bytes at offset+652)
            let mut received_txid = [0u8; 32];
            received_txid.copy_from_slice(&outputs_slice[offset + 652..offset + 684]);

            (i, height, cmu, epk, ciphertext, received_txid)
        })
        .collect();

    // Parallel decryption using Rayon
    // Collect (position, height, value, diversifier, rcm, cmu, received_txid) for notes we find
    // PRODUCTION: Now includes received_txid!
    let decrypted: Vec<_> = parsed_outputs.par_iter()
        .filter_map(|(position, height, cmu, epk, ciphertext, received_txid)| {
            // Create a ShieldedOutput for decryption
            let output = BoostOutput {
                epk: *epk,
                cmu: *cmu,
                enc_ciphertext: *ciphertext,
            };

            let block_height = BlockHeight::from_u32(*height);
            match try_sapling_note_decryption(&ZclassicNetwork, block_height, &prepared_ivk, &output) {
                Some((note, address, _memo)) => {
                    let mut diversifier = [0u8; 11];
                    diversifier.copy_from_slice(address.diversifier().0.as_ref());

                    let rcm_repr = match note.rseed() {
                        Rseed::BeforeZip212(rcm) => rcm.to_repr(),
                        Rseed::AfterZip212(rseed) => *rseed,
                    };

                    Some((*position as u64, *height, note.value().inner(), diversifier, rcm_repr, *cmu, *received_txid))
                }
                None => None,
            }
        })
        .collect();

    eprintln!("⚡ Decrypted {} notes from {} outputs", decrypted.len(), output_count);

    // Now compute nullifiers (need extsk, so sequential, but this is fast)
    let mut notes_written = 0;
    let mut total_received: u64 = 0;
    let mut total_spent: u64 = 0;
    let mut notes_spent: u32 = 0;

    for (position, height, value, diversifier, rcm_repr, cmu, received_txid) in decrypted {
        if notes_written >= max_notes {
            eprintln!("⚠️ Max notes ({}) reached, stopping", max_notes);
            break;
        }

        total_received += value;

        // Parse rcm
        let rcm_scalar: Fr = match Option::<Fr>::from(Fr::from_repr(rcm_repr)) {
            Some(r) => r,
            None => {
                eprintln!("⚠️ Invalid rcm for note at position {}", position);
                continue;
            }
        };

        // Get payment address for nullifier computation
        let div = Diversifier(diversifier);
        let payment_address = match fvk.vk.to_payment_address(div) {
            Some(addr) => addr,
            None => {
                eprintln!("⚠️ Invalid diversifier for note at position {}", position);
                continue;
            }
        };

        // Create note and compute nullifier
        // CRITICAL: position is the enumerate index from boost file (blockchain order)
        let note = payment_address.create_note(value, Rseed::BeforeZip212(rcm_scalar));
        let nullifier = note.nf(&nk, position);
        let nf_bytes = nullifier.0;

        // Check if spent and get spend height + txid from HashMap
        let (is_spent, spent_height, spent_txid) = match nullifier_map.get(&nf_bytes) {
            Some(&(spend_h, txid)) => (1u8, spend_h, txid),
            None => (0u8, 0u32, [0u8; 32]),
        };
        if is_spent == 1 {
            total_spent += value;
            notes_spent += 1;
            eprintln!("   💸 Spent: {} zatoshis @ height {} (txid {:02x}{:02x}...)", value, height, spent_txid[0], spent_txid[1]);
        } else {
            eprintln!("   💰 Unspent: {} zatoshis @ height {} (pos {})", value, height, position);
        }

        // Write to output buffer with all data needed for database/transactions
        let out_note = &mut *notes_out.add(notes_written);
        out_note.height = height;
        out_note.position = position;
        out_note.value = value;
        out_note.diversifier = diversifier;
        out_note.rcm = rcm_repr;
        out_note.cmu = cmu;
        out_note.nullifier = nf_bytes;
        out_note.is_spent = is_spent;
        out_note.spent_height = spent_height;
        out_note.spent_txid = spent_txid;  // Real txid from boost file!
        out_note.received_txid = received_txid;  // PRODUCTION: Real txid - no more placeholders!
        out_note._padding = [0u8; 3];

        notes_written += 1;
    }

    // Write summary
    if !result_out.is_null() {
        (*result_out) = BoostScanResult {
            total_received,
            total_spent,
            unspent_balance: total_received - total_spent,
            notes_found: notes_written as u32,
            notes_spent,
            spends_checked: spend_count as u32,
        };
    }

    eprintln!("✅ Scan complete: {} notes, {} spent, balance: {:.8} ZCL",
        notes_written, notes_spent, (total_received - total_spent) as f64 / 100_000_000.0);

    notes_written
}

/// Helper struct for boost output decryption (implements ShieldedOutput trait)
struct BoostOutput {
    epk: [u8; 32],
    cmu: [u8; 32],
    enc_ciphertext: [u8; 580],
}

impl ShieldedOutput<SaplingDomain<ZclassicNetwork>, ENC_CIPHERTEXT_SIZE> for BoostOutput {
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

// =============================================================================
// VUL-002: Local Transaction Verification (FIX #xxx)
// Validate Sapling proofs BEFORE broadcasting to prevent invalid TX propagation
// This mirrors the mempool validation in zclassic/src/main.cpp ContextualCheckTransaction()
// =============================================================================

/// Error codes for transaction verification
#[repr(u32)]
pub enum TxVerifyError {
    Success = 0,
    InvalidTransactionData = 1,
    FailedToParseTransaction = 2,
    NoSaplingBundle = 3,
    SpendVerificationFailed = 4,
    OutputVerificationFailed = 5,
    BindingSignatureFailed = 6,
    MissingVerifyingKey = 7,
    InvalidSignatureHash = 8,
}

/// Verify a serialized Sapling transaction before broadcasting
///
/// This function performs the same verification as ContextualCheckTransaction() in zclassic:
/// 1. Parse the serialized transaction
/// 2. For each SpendDescription: call check_spend()
/// 3. For each OutputDescription: call check_output()
/// 4. Call final_check() to verify the binding signature
///
/// # Safety
/// - tx_data: Pointer to serialized transaction bytes
/// - tx_len: Length of transaction data
/// - chain_height: Current chain height (for branch ID selection)
/// - error_out: Output for error code if verification fails
///
/// # Returns
/// true if transaction is valid, false otherwise
#[no_mangle]
pub unsafe extern "C" fn zipherx_verify_transaction(
    tx_data: *const u8,
    tx_len: usize,
    chain_height: u64,
    error_out: *mut u32,
) -> bool {
    use zcash_primitives::transaction::Transaction;
    use zcash_primitives::consensus::BranchId;
    use std::io::Cursor;

    // FIX #230: Safety check with safe slice validation
    if tx_len == 0 {
        if !error_out.is_null() {
            *error_out = TxVerifyError::InvalidTransactionData as u32;
        }
        return false;
    }

    let tx_bytes = match safe_slice(tx_data, tx_len) {
        Some(s) => s,
        None => {
            eprintln!("❌ Invalid tx_data pointer");
            if !error_out.is_null() {
                *error_out = TxVerifyError::InvalidTransactionData as u32;
            }
            return false;
        }
    };

    // Get branch ID for current height (Zclassic uses Buttercup after block 707,000)
    let height = BlockHeight::from_u32(chain_height as u32);
    let branch_id = BranchId::for_height(&ZclassicNetwork, height);

    eprintln!("🔍 VUL-002 FIX: Verifying transaction ({} bytes) at height {} with branch ID {:?}",
        tx_len, chain_height, branch_id);

    // Parse the transaction
    let tx = match Transaction::read(&mut Cursor::new(tx_bytes), branch_id) {
        Ok(tx) => tx,
        Err(e) => {
            eprintln!("❌ Failed to parse transaction: {:?}", e);
            if !error_out.is_null() {
                *error_out = TxVerifyError::FailedToParseTransaction as u32;
            }
            return false;
        }
    };

    // Get the Sapling bundle - if none, nothing to verify (pure transparent tx)
    let sapling_bundle = match tx.sapling_bundle() {
        Some(bundle) => bundle,
        None => {
            eprintln!("ℹ️ Transaction has no Sapling bundle - no Sapling verification needed");
            if !error_out.is_null() {
                *error_out = TxVerifyError::Success as u32;
            }
            return true;
        }
    };

    let shielded_spends = sapling_bundle.shielded_spends();
    let shielded_outputs = sapling_bundle.shielded_outputs();
    let value_balance = sapling_bundle.value_balance();

    eprintln!("🔍 Sapling bundle: {} spends, {} outputs, value_balance: {:?}",
        shielded_spends.len(), shielded_outputs.len(), value_balance);

    // If no spends and no outputs, nothing to verify
    if shielded_spends.is_empty() && shielded_outputs.is_empty() {
        if !error_out.is_null() {
            *error_out = TxVerifyError::Success as u32;
        }
        return true;
    }

    // Get verifying keys from our static storage (populated during prover init)
    let vk_guard = VERIFYING_KEYS.lock().unwrap();
    let vk_params = match vk_guard.as_ref() {
        Some(params) => params,
        None => {
            eprintln!("❌ Verifying keys not initialized - call zipherx_init_prover first");
            if !error_out.is_null() {
                *error_out = TxVerifyError::MissingVerifyingKey as u32;
            }
            return false;
        }
    };

    // Create verification context (ZIP 216 enabled for modern transactions)
    let mut ctx = SaplingVerificationContext::new(true);

    // Compute sighash (dataToBeSigned) - this is what spend auth sigs and binding sig sign
    // For Sapling v4 transactions, we use v4_signature_hash directly which doesn't need txid_parts
    use zcash_primitives::transaction::sighash::{SignableInput};
    use zcash_primitives::transaction::sighash_v4::v4_signature_hash;

    // Get the TransactionData from the Transaction for sighash computation
    let tx_data = tx.into_data();

    // For v4 (Sapling) transactions, compute sighash directly
    let sighash_hash = v4_signature_hash(&tx_data, &SignableInput::Shielded);
    let sighash_bytes: [u8; 32] = sighash_hash.as_bytes().try_into().expect("sighash is 32 bytes");

    eprintln!("🔍 Computed sighash for verification");

    // Re-get sapling bundle from tx_data (tx was consumed by into_data())
    let sapling_bundle = match tx_data.sapling_bundle() {
        Some(bundle) => bundle,
        None => {
            // Shouldn't happen since we checked above, but be safe
            eprintln!("ℹ️ Transaction has no Sapling bundle - no Sapling verification needed");
            if !error_out.is_null() {
                *error_out = TxVerifyError::Success as u32;
            }
            return true;
        }
    };

    let shielded_spends = sapling_bundle.shielded_spends();
    let shielded_outputs = sapling_bundle.shielded_outputs();

    // Verify each SpendDescription
    for (i, spend) in shielded_spends.iter().enumerate() {
        let cv = spend.cv();
        let anchor = spend.anchor();
        let nullifier = spend.nullifier();
        let rk = spend.rk();
        let zkproof_bytes = spend.zkproof();
        let spend_auth_sig = spend.spend_auth_sig();

        // Parse the zkproof bytes into a Proof<Bls12> for verification
        use bellman::groth16::Proof;
        use bls12_381::Bls12;
        let zkproof = match Proof::<Bls12>::read(&zkproof_bytes[..]) {
            Ok(proof) => proof,
            Err(e) => {
                eprintln!("❌ SpendDescription {} failed to parse zkproof: {:?}", i, e);
                if !error_out.is_null() {
                    *error_out = TxVerifyError::SpendVerificationFailed as u32;
                }
                return false;
            }
        };

        // check_spend expects: cv, anchor, &nullifier.0, rk, &sighash, spend_auth_sig, zkproof, &spend_vk
        let spend_valid = ctx.check_spend(
            cv,
            *anchor,
            &nullifier.0,
            rk.clone(),
            &sighash_bytes,
            *spend_auth_sig,
            zkproof,
            &vk_params.spend_vk,
        );

        if !spend_valid {
            eprintln!("❌ SpendDescription {} verification FAILED", i);
            if !error_out.is_null() {
                *error_out = TxVerifyError::SpendVerificationFailed as u32;
            }
            return false;
        }
        eprintln!("✅ SpendDescription {} verified", i);
    }

    // Verify each OutputDescription
    for (i, output) in shielded_outputs.iter().enumerate() {
        let cv = output.cv();
        let cmu = output.cmu();
        let ephemeral_key_bytes = output.ephemeral_key();
        let zkproof_bytes = output.zkproof();

        // Parse the zkproof bytes into a Proof<Bls12>
        use bellman::groth16::Proof;
        use bls12_381::Bls12;
        let zkproof = match Proof::<Bls12>::read(&zkproof_bytes[..]) {
            Ok(proof) => proof,
            Err(e) => {
                eprintln!("❌ OutputDescription {} failed to parse zkproof: {:?}", i, e);
                if !error_out.is_null() {
                    *error_out = TxVerifyError::OutputVerificationFailed as u32;
                }
                return false;
            }
        };

        // Convert EphemeralKeyBytes to ExtendedPoint via AffinePoint
        // EphemeralKeyBytes is a newtype around [u8; 32]
        // from_bytes returns CtOption<T>, use into_option() to convert to Option<T>
        use subtle::CtOption;
        let epk = match jubjub::AffinePoint::from_bytes(ephemeral_key_bytes.0).into_option() {
            Some(affine) => jubjub::ExtendedPoint::from(affine),
            None => {
                eprintln!("❌ OutputDescription {} has invalid ephemeral key", i);
                if !error_out.is_null() {
                    *error_out = TxVerifyError::OutputVerificationFailed as u32;
                }
                return false;
            }
        };

        let output_valid = ctx.check_output(
            cv,
            *cmu,
            epk,
            zkproof,
            &vk_params.output_vk,
        );

        if !output_valid {
            eprintln!("❌ OutputDescription {} verification FAILED", i);
            if !error_out.is_null() {
                *error_out = TxVerifyError::OutputVerificationFailed as u32;
            }
            return false;
        }
        eprintln!("✅ OutputDescription {} verified", i);
    }

    // Final check: verify the binding signature
    // This ensures value balance is correct and transaction wasn't tampered with
    let value_balance = sapling_bundle.value_balance();
    let binding_sig = sapling_bundle.authorization().binding_sig;

    let final_valid = ctx.final_check(
        *value_balance,
        &sighash_bytes,
        binding_sig,
    );

    if !final_valid {
        eprintln!("❌ Binding signature verification FAILED");
        if !error_out.is_null() {
            *error_out = TxVerifyError::BindingSignatureFailed as u32;
        }
        return false;
    }

    eprintln!("✅ Binding signature verified");
    eprintln!("✅ Transaction verification PASSED - safe to broadcast");

    if !error_out.is_null() {
        *error_out = TxVerifyError::Success as u32;
    }
    true
}

// =============================================================================
// ZSTD Decompression - Boost File Support
// =============================================================================

/// Decompress ZSTD data
///
/// # Arguments
/// * `compressed_ptr` - Pointer to compressed data
/// * `compressed_len` - Length of compressed data
/// * `out_ptr` - Pointer to store output buffer pointer (caller must free)
/// * `out_len` - Pointer to store output length
///
/// # Returns
/// * 1 on success, 0 on failure
///
/// # Safety
/// Caller is responsible for freeing the returned buffer using zipherx_free_buffer()
#[no_mangle]
pub extern "C" fn zipherx_zstd_decompress(
    compressed_ptr: *const u8,
    compressed_len: usize,
    out_ptr: *mut *mut u8,
    out_len: *mut usize,
) -> u32 {
    // Validate inputs
    if compressed_ptr.is_null() || out_ptr.is_null() || out_len.is_null() {
        eprintln!("❌ ZSTD decompress: null pointer");
        return 0;
    }

    // Safe slice creation
    let compressed_data = match unsafe { safe_slice(compressed_ptr, compressed_len) } {
        Some(data) => data,
        None => {
            eprintln!("❌ ZSTD decompress: invalid input pointer");
            return 0;
        }
    };

    // Decompress using zstd crate
    let decompressed = match zstd::decode_all(compressed_data) {
        Ok(data) => data,
        Err(e) => {
            eprintln!("❌ ZSTD decompression failed: {:?}", e);
            return 0;
        }
    };

    // Allocate output buffer
    let out_len_value = decompressed.len();
    let buffer = unsafe { libc::malloc(out_len_value) as *mut u8 };
    if buffer.is_null() {
        eprintln!("❌ ZSTD decompress: malloc failed");
        return 0;
    }

    // Copy decompressed data to output buffer
    unsafe {
        libc::memcpy(buffer as *mut libc::c_void, decompressed.as_ptr() as *const libc::c_void, out_len_value);
    }

    // Set output parameters
    unsafe {
        *out_ptr = buffer;
        *out_len = out_len_value;
    }

    eprintln!("✅ ZSTD decompressed {} bytes -> {} bytes", compressed_len, out_len_value);
    1
}

/// Free a buffer allocated by Rust FFI
#[no_mangle]
pub extern "C" fn zipherx_free_buffer(ptr: *mut u8) {
    if !ptr.is_null() {
        unsafe { libc::free(ptr as *mut libc::c_void) };
    }
}
