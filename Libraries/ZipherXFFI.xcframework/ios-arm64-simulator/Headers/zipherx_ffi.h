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

// Spend information for multi-input transactions
typedef struct {
    const uint8_t *witness_data;    // Serialized IncrementalWitness data
    size_t witness_len;              // Length of witness data
    uint64_t note_value;             // Note value in zatoshis
    const uint8_t *note_rcm;         // Note commitment randomness (32 bytes)
    const uint8_t *note_diversifier; // Note diversifier (11 bytes)
} SpendInfo;

// Build a shielded transaction with multiple input notes
// spends: array of SpendInfo pointers
// spend_count: number of spends
// nullifiers_out: output buffer for nullifiers (32 bytes * spend_count)
bool zipherx_build_transaction_multi(
    const uint8_t *sk,
    const uint8_t *to_address,
    uint64_t amount,
    const uint8_t *memo,
    const SpendInfo *const *spends,
    size_t spend_count,
    uint64_t chain_height,
    uint8_t *tx_out,
    size_t *tx_out_len,
    uint8_t *nullifiers_out
);

// Commitment tree functions
bool zipherx_tree_init(void);
uint64_t zipherx_tree_append(const uint8_t *cmu);
uint64_t zipherx_tree_append_batch(const uint8_t *cmus_data, size_t cmu_count);  // Batch append (faster)
uint64_t zipherx_tree_witness_current(void);
bool zipherx_tree_root(uint8_t *root_out);
bool zipherx_tree_get_witness(uint64_t witness_index, uint8_t *witness_out);
uint64_t zipherx_tree_size(void);
bool zipherx_tree_serialize(uint8_t *tree_out, size_t *tree_out_len);
bool zipherx_tree_deserialize(const uint8_t *tree_data, size_t tree_len);

// Load commitment tree from bundled CMU file
bool zipherx_tree_load_from_cmus(const uint8_t *data, size_t data_len);

// Progress callback type for tree loading: (current, total)
typedef void (*TreeLoadProgressCallback)(uint64_t current, uint64_t total);

// Load commitment tree from bundled CMU file with progress callback
bool zipherx_tree_load_from_cmus_with_progress(
    const uint8_t *data,
    size_t data_len,
    TreeLoadProgressCallback progress_callback
);

// Create witness for a specific CMU from bundled data
uint64_t zipherx_tree_create_witness_for_cmu(
    const uint8_t *cmu_data,
    size_t cmu_data_len,
    const uint8_t *target_cmu,
    uint8_t *witness_out,
    size_t *witness_out_len
);

// Find position of a CMU in bundled data (fast, no tree building)
uint64_t zipherx_find_cmu_position(
    const uint8_t *cmu_data,
    size_t cmu_data_len,
    const uint8_t *target_cmu
);

// Create witnesses for MULTIPLE CMUs in a SINGLE tree pass (batch operation)
// Much faster than calling zipherx_tree_create_witness_for_cmu multiple times
// because it only builds the tree ONCE instead of N times.
//
// Parameters:
// - cmu_data: Bundled CMU file [count: u64][cmu1: 32]...
// - cmu_data_len: Length of CMU data
// - target_cmus: Array of 32-byte CMUs to create witnesses for
// - target_count: Number of target CMUs
// - positions_out: Output array for positions (u64 * target_count)
// - witnesses_out: Output array for witnesses (1028 bytes * target_count)
//
// Returns: Number of witnesses successfully created
size_t zipherx_tree_create_witnesses_batch(
    const uint8_t *cmu_data,
    size_t cmu_data_len,
    const uint8_t *target_cmus,
    size_t target_count,
    uint64_t *positions_out,
    uint8_t *witnesses_out
);

// Create witnesses for MULTIPLE CMUs using PARALLEL processing (Rayon)
// This is the FASTEST option - uses all CPU cores via Rayon work-stealing.
// Each witness gets its own thread building tree to that position.
//
// Parameters: same as zipherx_tree_create_witnesses_batch
// Returns: Number of witnesses successfully created
size_t zipherx_tree_create_witnesses_parallel(
    const uint8_t *target_cmus,
    size_t target_count,
    const uint8_t *cmu_data,
    size_t cmu_data_len,
    uint64_t *positions_out,
    uint8_t *witnesses_out
);

// Compute nullifier for a note
bool zipherx_compute_nullifier(
    const uint8_t *spending_key,
    const uint8_t *diversifier,
    uint64_t value,
    const uint8_t *rcm,
    uint64_t position,
    uint8_t *nf_out
);

// =============================================================================
// Parallel Note Decryption (Rayon-based, ~6.7x speedup)
// =============================================================================

// Batch decrypt multiple shielded outputs in parallel using Rayon
//
// Input format (per output, 644 bytes total):
// - epk: 32 bytes (ephemeral public key)
// - cmu: 32 bytes (note commitment)
// - ciphertext: 580 bytes (encrypted note)
//
// Output format (per output, 564 bytes total):
// - found: 1 byte (0 = not ours, 1 = decrypted successfully)
// - diversifier: 11 bytes (only valid if found == 1)
// - value: 8 bytes little-endian u64 (only valid if found == 1)
// - rcm: 32 bytes (only valid if found == 1)
// - memo: 512 bytes (only valid if found == 1)
//
// Parameters:
// - sk: spending key (169 bytes)
// - outputs_data: packed array of outputs (644 bytes each)
// - output_count: number of outputs to process
// - height: block height (for version byte validation)
// - results: output buffer (564 bytes per output)
//
// Returns: number of successfully decrypted notes
size_t zipherx_try_decrypt_notes_parallel(
    const uint8_t *sk,
    const uint8_t *outputs_data,
    size_t output_count,
    uint64_t height,
    uint8_t *results
);

// Get the number of CPU threads Rayon will use for parallel decryption
size_t zipherx_get_rayon_threads(void);

// =============================================================================
// Equihash Proof-of-Work Verification (for trustless header validation)
// =============================================================================

// Verify Equihash(200,9) solution for a block header
// header_bytes: 140-byte block header (includes 32-byte nonce at end)
// solution: Equihash solution bytes (typically 1344 bytes)
// solution_len: Length of solution
// Returns true if solution is valid
bool zipherx_verify_equihash(
    const uint8_t *header_bytes,
    const uint8_t *solution,
    size_t solution_len
);

// Compute block hash (double SHA256) from header + solution
// header_bytes: 140-byte block header
// solution: Equihash solution bytes
// solution_len: Length of solution
// hash_out: Output buffer for 32-byte hash (internal byte order)
// Returns true on success
bool zipherx_compute_block_hash(
    const uint8_t *header_bytes,
    const uint8_t *solution,
    size_t solution_len,
    uint8_t *hash_out
);

// Verify a chain of block headers for continuity and valid PoW
// headers_data: Concatenated header data (140 bytes + varint + solution each)
// headers_count: Number of headers
// expected_prev_hash: Expected prevHash of first header (32 bytes), or NULL
// header_offsets: Array of byte offsets for each header
// header_sizes: Array of total sizes for each header
// Returns true if all headers valid and chain is continuous
bool zipherx_verify_header_chain(
    const uint8_t *headers_data,
    size_t headers_count,
    const uint8_t *expected_prev_hash,
    const size_t *header_offsets,
    const size_t *header_sizes
);

// Verify a single block header and get its hash
// header_and_solution: Full header data (140 bytes + varint + solution)
// total_len: Total length of data
// hash_out: Output buffer for 32-byte block hash
// Returns true if header is valid
bool zipherx_verify_block_header(
    const uint8_t *header_and_solution,
    size_t total_len,
    uint8_t *hash_out
);

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
// The encryption key (32 bytes) is derived from device ID + salt using HKDF
// on the Swift side and passed separately.

// Build a shielded transaction using an encrypted spending key (VUL-002 secure)
// encrypted_sk: 197-byte AES-GCM encrypted spending key (nonce + ciphertext + tag)
// encrypted_sk_len: length of encrypted key (should be 197)
// encryption_key: 32-byte AES-256 key for decryption
// Other parameters same as zipherx_build_transaction
bool zipherx_build_transaction_encrypted(
    const uint8_t *encrypted_sk,
    size_t encrypted_sk_len,
    const uint8_t *encryption_key,
    const uint8_t *to_address,
    uint64_t amount,
    const uint8_t *memo,
    const uint8_t *anchor,
    const uint8_t *witness_data,
    size_t witness_len,
    uint64_t note_value,
    const uint8_t *note_rcm,
    const uint8_t *note_diversifier,
    uint64_t chain_height,
    uint8_t *tx_out,
    size_t *tx_out_len
);

// Build a shielded transaction with multiple inputs using encrypted spending key (VUL-002 secure)
// encrypted_sk: 197-byte AES-GCM encrypted spending key
// encrypted_sk_len: length of encrypted key (should be 197)
// encryption_key: 32-byte AES-256 key for decryption
// Other parameters same as zipherx_build_transaction_multi
bool zipherx_build_transaction_multi_encrypted(
    const uint8_t *encrypted_sk,
    size_t encrypted_sk_len,
    const uint8_t *encryption_key,
    const uint8_t *to_address,
    uint64_t amount,
    const uint8_t *memo,
    const SpendInfo *const *spends,
    size_t spend_count,
    uint64_t chain_height,
    uint8_t *tx_out,
    size_t *tx_out_len,
    uint8_t *nullifiers_out
);

// =============================================================================
// Boost File Scanning - Complete wallet scan in Rust
// =============================================================================

// Result for a discovered note from boost file scanning
// Contains all data needed to store in database and build transactions
typedef struct {
    uint32_t height;           // Block height where note was received
    uint64_t position;         // Position in commitment tree (for nullifier)
    uint64_t value;            // Note value in zatoshis
    uint8_t diversifier[11];   // Note diversifier
    uint8_t rcm[32];           // Random commitment
    uint8_t cmu[32];           // Note commitment
    uint8_t nullifier[32];     // Computed nullifier
    uint8_t is_spent;          // 1 if spent, 0 if unspent
    uint8_t _padding[4];       // Alignment padding
} BoostScanNote;

// Summary result from boost scan
typedef struct {
    uint64_t total_received;   // Total value of all notes found
    uint64_t total_spent;      // Total value of spent notes
    uint64_t unspent_balance;  // Final spendable balance
    uint32_t notes_found;      // Number of notes found
    uint32_t notes_spent;      // Number of notes that are spent
    uint32_t spends_checked;   // Number of spends in boost file
} BoostScanResult;

// Scan boost file outputs section and return discovered notes with nullifiers
// Performs complete PHASE 1 + PHASE 1.6 scanning:
// 1. Parse outputs from boost data (652 bytes per output)
// 2. Parse spends from boost data (36 bytes per spend)
// 3. Parallel note decryption using Rayon
// 4. Compute nullifiers for each discovered note
// 5. Check nullifiers against spends to detect spent notes
//
// Returns: Number of notes written to notes_out
size_t zipherx_scan_boost_outputs(
    const uint8_t *sk,              // Extended spending key (169 bytes)
    const uint8_t *outputs_data,    // Outputs section (652 bytes per output)
    size_t output_count,            // Number of outputs
    const uint8_t *spends_data,     // Spends section (36 bytes per spend)
    size_t spend_count,             // Number of spends
    BoostScanNote *notes_out,       // Output buffer for discovered notes
    size_t max_notes,               // Maximum notes that can fit
    BoostScanResult *result_out     // Output for scan summary
);

#endif // ZIPHERX_FFI_H
