//
//  ZipherX-Bridging-Header.h
//  ZipherX
//
//  Bridging header for Rust FFI functions
//

#ifndef ZipherX_Bridging_Header_h
#define ZipherX_Bridging_Header_h

#include <stdint.h>
#include <stdbool.h>

// =============================================================================
// Mnemonic Functions
// =============================================================================

/// Generate a 24-word BIP-39 mnemonic
/// @param output Buffer of at least 256 bytes
/// @return Length of mnemonic string, or 0 on failure
size_t zipherx_generate_mnemonic(uint8_t *output);

/// Validate a BIP-39 mnemonic
/// @param mnemonic Null-terminated mnemonic string
/// @return true if valid
bool zipherx_validate_mnemonic(const char *mnemonic);

/// Derive seed from mnemonic (PBKDF2-SHA512)
/// @param mnemonic Null-terminated mnemonic string
/// @param output Buffer of at least 64 bytes for seed
/// @return true on success
bool zipherx_mnemonic_to_seed(const char *mnemonic, uint8_t *output);

// =============================================================================
// Key Derivation Functions
// =============================================================================

/// Derive spending key from seed (outputs 96 bytes: ask+nsk+ovk)
/// @param seed 64-byte seed
/// @param account Account index
/// @param sk_out Buffer of at least 96 bytes for spending key components
/// @return true on success
bool zipherx_derive_spending_key(const uint8_t *seed, uint32_t account, uint8_t *sk_out);

/// Derive payment address from spending key
/// @param sk 96-byte spending key (ask+nsk+ovk)
/// @param diversifier_index Diversifier index
/// @param address_out Buffer of at least 43 bytes for address
/// @return true on success
bool zipherx_derive_address(const uint8_t *sk, uint64_t diversifier_index, uint8_t *address_out);

/// Derive incoming viewing key from spending key
/// @param sk 96-byte spending key
/// @param ivk_out Buffer of at least 32 bytes for ivk
/// @return true on success
bool zipherx_derive_ivk(const uint8_t *sk, uint8_t *ivk_out);

/// Compute nullifier for a note
/// @param viewing_key 32-byte viewing key
/// @param diversifier 11-byte diversifier
/// @param value Note value in zatoshis
/// @param rcm 32-byte randomness
/// @param position Note position in tree
/// @param nf_out Buffer of at least 32 bytes for nullifier
/// @return true on success
bool zipherx_compute_nullifier(const uint8_t *viewing_key,
                                const uint8_t *diversifier,
                                uint64_t value,
                                const uint8_t *rcm,
                                uint64_t position,
                                uint8_t *nf_out);

// =============================================================================
// Address Functions
// =============================================================================

/// Encode address bytes as Zclassic z-address string
/// @param address 43-byte address
/// @param output Buffer of at least 128 bytes
/// @return Length of encoded string
size_t zipherx_encode_address(const uint8_t *address, uint8_t *output);

/// Decode Zclassic z-address string to bytes
/// @param address_str Null-terminated z-address string
/// @param output Buffer of at least 43 bytes
/// @return true on success
bool zipherx_decode_address(const char *address_str, uint8_t *output);

/// Validate a z-address
/// @param address_str Null-terminated z-address string
/// @return true if valid
bool zipherx_validate_address(const char *address_str);

// =============================================================================
// Note Decryption
// =============================================================================

/// Try to decrypt a Sapling note with incoming viewing key
/// @param ivk 32-byte incoming viewing key
/// @param epk 32-byte ephemeral public key
/// @param cmu 32-byte note commitment
/// @param ciphertext 580-byte encrypted ciphertext
/// @param output Buffer of at least 564 bytes for decrypted plaintext
/// @return 564 on success (decrypted length), 0 if note not for us
size_t zipherx_try_decrypt_note(const uint8_t *ivk,
                                 const uint8_t *epk,
                                 const uint8_t *cmu,
                                 const uint8_t *ciphertext,
                                 uint8_t *output);

/// Try to decrypt a Sapling note using the spending key
/// Uses the full zcash_primitives derivation
/// @param sk 169-byte extended spending key
/// @param epk 32-byte ephemeral public key
/// @param cmu 32-byte note commitment
/// @param ciphertext 580-byte encrypted ciphertext
/// @param output Buffer of at least 564 bytes for decrypted plaintext
/// @return 564 on success (decrypted length), 0 if note not for us
size_t zipherx_try_decrypt_note_with_sk(const uint8_t *sk,
                                         const uint8_t *epk,
                                         const uint8_t *cmu,
                                         const uint8_t *ciphertext,
                                         uint8_t *output);

// =============================================================================
// Utility Functions
// =============================================================================

/// Get library version
/// @return Version number
uint32_t zipherx_version(void);

/// Double hash (BLAKE2b)
/// @param data Input data
/// @param len Input length
/// @param output Buffer of at least 32 bytes
/// @return true on success
bool zipherx_double_sha256(const uint8_t *data, size_t len, uint8_t *output);

/// Free a buffer allocated by the library
/// @param ptr Pointer to free
/// @param len Length of buffer
void zipherx_free(uint8_t *ptr, size_t len);

// =============================================================================
// Spending Key Encoding/Decoding (Bech32)
// =============================================================================

/// Encode spending key as Bech32 string (secret-extended-key-main1...)
/// @param sk 169-byte spending key
/// @param output Buffer of at least 512 bytes for encoded string
/// @return Length of encoded string, or 0 on failure
size_t zipherx_encode_spending_key(const uint8_t *sk, uint8_t *output);

/// Decode Bech32 spending key string to bytes
/// @param encoded Null-terminated Bech32 string
/// @param output Buffer of at least 169 bytes for spending key
/// @return true on success
bool zipherx_decode_spending_key(const char *encoded, uint8_t *output);

// =============================================================================
// Transaction Building Functions
// =============================================================================

/// Initialize the prover with Sapling parameters
/// @param spend_path Path to sapling-spend.params
/// @param output_path Path to sapling-output.params
/// @return true on success
bool zipherx_init_prover(const char *spend_path, const char *output_path);

/// Build a complete shielded transaction
/// @param sk Extended spending key (169 bytes)
/// @param to_address Destination address bytes (43 bytes)
/// @param amount Amount in zatoshis
/// @param memo Optional memo (512 bytes)
/// @param anchor Merkle tree anchor (32 bytes)
/// @param witness_data Serialized witness
/// @param witness_len Length of witness data
/// @param note_value Value of note being spent
/// @param note_rcm Note randomness (32 bytes)
/// @param note_diversifier Note diversifier (11 bytes)
/// @param tx_out Output buffer for transaction (at least 10000 bytes)
/// @param tx_out_len Output for transaction length
/// @return true on success
bool zipherx_build_transaction(const uint8_t *sk,
                                const uint8_t *to_address,
                                uint64_t amount,
                                const uint8_t *memo,
                                const uint8_t *anchor,
                                const uint8_t *witness_data,
                                size_t witness_len,
                                uint64_t note_value,
                                const uint8_t *note_rcm,
                                const uint8_t *note_diversifier,
                                uint8_t *tx_out,
                                size_t *tx_out_len);

/// Compute a value commitment
/// @param value Value in zatoshis
/// @param rcv 32-byte random scalar
/// @param cv_out Buffer for 32-byte commitment
/// @return true on success
bool zipherx_compute_value_commitment(uint64_t value, const uint8_t *rcv, uint8_t *cv_out);

/// Generate a random scalar
/// @param output Buffer for 32-byte scalar
/// @return true on success
bool zipherx_random_scalar(uint8_t *output);

/// Encrypt note plaintext
/// @param diversifier 11-byte diversifier
/// @param pk_d 32-byte pk_d
/// @param value Note value
/// @param rcm 32-byte randomness
/// @param memo 512-byte memo
/// @param epk_out Output for 32-byte ephemeral key
/// @param enc_out Output for 580-byte ciphertext
/// @return true on success
bool zipherx_encrypt_note(const uint8_t *diversifier,
                           const uint8_t *pk_d,
                           uint64_t value,
                           const uint8_t *rcm,
                           const uint8_t *memo,
                           uint8_t *epk_out,
                           uint8_t *enc_out);

#endif /* ZipherX_Bridging_Header_h */
