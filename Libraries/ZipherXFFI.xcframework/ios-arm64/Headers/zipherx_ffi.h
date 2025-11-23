#ifndef ZIPHERX_FFI_H
#define ZIPHERX_FFI_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

// Key generation
size_t zipherx_generate_mnemonic(uint8_t *output);
bool zipherx_validate_mnemonic(const char *mnemonic);
bool zipherx_mnemonic_to_seed(const char *mnemonic, uint8_t *seed_out);
bool zipherx_derive_spending_key(const uint8_t *seed, uint32_t account, uint8_t *sk_out);
bool zipherx_derive_address(const uint8_t *sk, uint8_t *addr_out);

// Address encoding/decoding
bool zipherx_encode_address(const uint8_t *addr_bytes, char *addr_str_out);
bool zipherx_decode_address(const char *addr_str, uint8_t *addr_bytes_out);

// Note decryption
bool zipherx_try_decrypt_note(
    const uint8_t *sk,
    const uint8_t *epk,
    const uint8_t *ciphertext,
    const uint8_t *cmu,
    uint64_t *value_out,
    uint8_t *rcm_out,
    uint8_t *memo_out,
    uint8_t *nf_out
);

// Full viewing key derivation
bool zipherx_derive_fvk(const uint8_t *sk, uint8_t *fvk_out);
bool zipherx_derive_ivk(const uint8_t *fvk, uint8_t *ivk_out);

// Prover initialization
bool zipherx_init_prover(const char *spend_path, const char *output_path);

// Transaction building
bool zipherx_build_transaction(
    const uint8_t *sk,
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
    size_t *tx_out_len
);

// Commitment tree functions
bool zipherx_tree_init(void);
uint64_t zipherx_tree_append(const uint8_t *cmu);
uint64_t zipherx_tree_witness_current(void);
bool zipherx_tree_root(uint8_t *root_out);
bool zipherx_tree_get_witness(uint64_t witness_index, uint8_t *witness_out);
uint64_t zipherx_tree_size(void);
bool zipherx_tree_serialize(uint8_t *tree_out, size_t *tree_out_len);
bool zipherx_tree_deserialize(const uint8_t *tree_data, size_t tree_len);

#endif // ZIPHERX_FFI_H
