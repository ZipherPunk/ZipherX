#ifndef ZIPHERX_FFI_H
#define ZIPHERX_FFI_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

// SQLCipher - encrypted SQLite
// sqlite3.h is available via HEADER_SEARCH_PATHS in Xcode project
#include <sqlite3.h>

// Key generation
size_t zipherx_generate_mnemonic(uint8_t *output);
bool zipherx_validate_mnemonic(const char *mnemonic);
bool zipherx_mnemonic_to_seed(const char *mnemonic, uint8_t *seed_out);
bool zipherx_derive_spending_key(const uint8_t *seed, uint32_t account, uint8_t *sk_out);
bool zipherx_derive_address(const uint8_t *sk, uint64_t diversifier_index, uint8_t *addr_out);

// Address encoding/decoding
size_t zipherx_encode_address(const uint8_t *addr_bytes, uint8_t *output);
bool zipherx_decode_address(const char *addr_str, uint8_t *output);

// Note decryption
// Decrypt note using IVK (32 bytes) - returns decrypted data length
size_t zipherx_try_decrypt_note(
    const uint8_t *ivk,       // 32 bytes
    const uint8_t *epk,       // 32 bytes
    const uint8_t *cmu,       // 32 bytes
    const uint8_t *ciphertext,// 580 bytes
    uint8_t *output           // 564 bytes output
);

// Decrypt note using spending key directly (169 bytes)
size_t zipherx_try_decrypt_note_with_sk(
    const uint8_t *sk,        // 169 bytes
    const uint8_t *epk,       // 32 bytes
    const uint8_t *cmu,       // 32 bytes
    const uint8_t *ciphertext,// 580 bytes
    uint8_t *output           // 564 bytes output
);

// Full viewing key derivation
bool zipherx_derive_fvk(const uint8_t *sk, uint8_t *fvk_out);
bool zipherx_derive_ivk(const uint8_t *fvk, uint8_t *ivk_out);

/// Derive outgoing viewing key from spending key
bool zipherx_derive_ovk(const uint8_t *sk, uint8_t *ovk_out);

// Prover initialization
bool zipherx_init_prover(const char *spend_path, const char *output_path);

/// Initialize prover from memory (for macOS Hardened Runtime)
bool zipherx_init_prover_from_bytes(
    const uint8_t *spend_data,
    size_t spend_len,
    const uint8_t *output_data,
    size_t output_len
);

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
    uint64_t chain_height,
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
uint64_t zipherx_witnesses_clear(void);  // FIX #996: Clear WITNESSES array before loading
uint64_t zipherx_tree_append(const uint8_t *cmu);
uint64_t zipherx_tree_append_batch(const uint8_t *cmus_data, size_t cmu_count);  // Batch append (faster)

/// FIX #840: ATOMIC delta CMU append - prevents race condition double-append
/// Returns: 0=error, 1=appended, 2=skipped (already present), 3=mismatch (tree too small)
uint32_t zipherx_tree_append_delta_atomic(
    const uint8_t *cmus_data,
    size_t cmu_count,
    uint64_t expected_boost_size
);

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

// FIX #580: Create witness from tree data + CMU position (instant, no P2P needed)
// This is the KEY optimization - generates witness in ~1ms instead of 84s P2P rebuild
// Parameters:
// - tree_data: Bundled CMU data [count: u64][cmu1: 32]...
// - tree_data_len: Length of tree data
// - position: Position of CMU in tree (0-indexed)
// - witness_out: Output buffer for witness (1028 bytes minimum)
// - witness_out_len: Output for actual witness length
// Returns: true on success, false on failure
bool zipherx_tree_create_witness_for_position(
    const uint8_t *tree_data,
    size_t tree_data_len,
    uint64_t position,
    uint8_t *witness_out,
    size_t *witness_out_len
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

// FIX #588: Rebuild corrupted witnesses at SPECIFIC positions
// Unlike zipherx_tree_create_witnesses_batch which builds ALL witnesses to the end
// of the boost file (giving them the same root), this function creates each witness
// at its specific position. This is critical for notes with different received_heights.
//
// This fixes the issue where witnesses have corrupted Merkle paths (filled_nodes)
// due to old FIX #585 trimming code that zeroed out trailing bytes.
//
// Parameters:
// - cmu_data: Bundled CMU file [count: u64][cmu1: 32]...
// - cmu_data_len: Length of CMU data
// - target_cmus: Array of 32-byte CMUs to rebuild witnesses for
// - target_positions: Array of positions (u64) for each CMU in the tree
// - target_count: Number of target CMUs
// - witnesses_out: Output array for witnesses (1028 bytes * target_count)
//
// Returns: Number of witnesses successfully created
size_t zipherx_tree_rebuild_witnesses_at_positions(
    const uint8_t *cmu_data,
    size_t cmu_data_len,
    const uint8_t *target_cmus,
    const uint64_t *target_positions,
    size_t target_count,
    uint8_t *witnesses_out
);

// Extract the Merkle root (anchor) from a serialized witness
// witness_data: serialized witness (1028 bytes from treeCreateWitnessesBatch)
// witness_len: length of witness data
// root_out: 32-byte output buffer for the root
// Returns: true if successful
bool zipherx_witness_get_root(
    const uint8_t *witness_data,
    size_t witness_len,
    uint8_t *root_out
);

// Check if the witness path is valid (not corrupted)
// A corrupted witness might have a valid root() but invalid path()
// The path is used by Zcash builder to create the zk-SNARK proof
// witness_data: serialized witness (1028 bytes)
// witness_len: length of witness data
// Returns: true if path is valid, false if corrupted
bool zipherx_witness_path_is_valid(
    const uint8_t *witness_data,
    size_t witness_len
);

// FIX #827: Verify witness anchor consistency
// Checks if witness.root() == merkle_path.root(cmu)
// A witness can pass witnessPathIsValid but still have corrupted path data
// Parameters:
// witness_data: serialized witness
// witness_len: length of witness data
// cmu_data: 32-byte CMU of the note
// Returns: true if consistent, false if corrupted
bool zipherx_witness_verify_anchor(
    const uint8_t *witness_data,
    size_t witness_len,
    const uint8_t *cmu_data
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

// FIX #1326: Real-time Groth16 proof progress (for UI countdown timer)
// Swift polls these every ~200ms during transaction building
uint32_t zipherx_get_proof_total(void);      // Total spend proofs to generate
uint32_t zipherx_get_proof_completed(void);  // Proofs completed so far (atomic)
uint32_t zipherx_get_proof_threads(void);    // Threads in proof pool (for time estimate)

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
// PRODUCTION: Now includes spent_txid and received_txid (FIX #374)
typedef struct {
    uint32_t height;           // Block height where note was received
    uint64_t position;         // Position in commitment tree (for nullifier)
    uint64_t value;            // Note value in zatoshis
    uint8_t diversifier[11];   // Note diversifier
    uint8_t rcm[32];           // Random commitment
    uint8_t cmu[32];           // Note commitment
    uint8_t nullifier[32];     // Computed nullifier
    uint8_t is_spent;          // 1 if spent, 0 if unspent
    uint32_t spent_height;     // Block height where note was spent (0 if unspent)
    uint8_t spent_txid[32];    // Real txid of spending transaction
    uint8_t received_txid[32]; // Real txid that created this output
    uint8_t _padding[3];       // Alignment padding
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

// =============================================================================
// Transaction Verification (FIX #xxx - VUL-002)
// Validate Sapling proofs BEFORE broadcasting to prevent invalid TX propagation
// =============================================================================

/// Error codes for transaction verification
typedef enum {
    TX_VERIFY_SUCCESS = 0,
    TX_VERIFY_INVALID_DATA = 1,
    TX_VERIFY_PARSE_FAILED = 2,
    TX_VERIFY_NO_SAPLING_BUNDLE = 3,
    TX_VERIFY_SPEND_FAILED = 4,
    TX_VERIFY_OUTPUT_FAILED = 5,
    TX_VERIFY_BINDING_SIG_FAILED = 6,
    TX_VERIFY_MISSING_KEY = 7,
    TX_VERIFY_INVALID_SIGHASH = 8
} TxVerifyError;

/// Verify a serialized Sapling transaction before broadcasting
/// This performs the same validation as zclassic's mempool acceptance:
/// - Validates all SpendDescription proofs
/// - Validates all OutputDescription proofs
/// - Validates the binding signature
///
/// @param tx_data Serialized transaction bytes
/// @param tx_len Length of transaction data
/// @param chain_height Current chain height (for branch ID selection)
/// @param error_out Pointer to receive error code on failure
/// @return true if transaction is valid, false otherwise
bool zipherx_verify_transaction(
    const uint8_t *tx_data,
    size_t tx_len,
    uint64_t chain_height,
    uint32_t *error_out
);

// =============================================================================
// Tor (Arti) Integration
// =============================================================================

// Start the embedded Tor client
// Returns 0 on success, 1 on error
int32_t zipherx_tor_start(void);

// Stop the Tor client
// Returns 0 on success
int32_t zipherx_tor_stop(void);

// Get current Tor state
// 0 = Disconnected, 1 = Connecting, 2 = Bootstrapping, 3 = Connected, 4 = Error
uint8_t zipherx_tor_get_state(void);

// Get bootstrap progress (0-100)
uint8_t zipherx_tor_get_progress(void);

// Get SOCKS proxy port (0 if not connected)
uint16_t zipherx_tor_get_socks_port(void);

// Get last error message
// Returns pointer to null-terminated string (caller must free with zipherx_tor_free_string)
char* zipherx_tor_get_error(void);

// Request new Tor identity (new circuit)
// Returns 0 on success
int32_t zipherx_tor_new_identity(void);

// Make an HTTP GET request through Tor
// Returns response body as null-terminated string (caller must free with zipherx_tor_free_string)
// Returns NULL on error
char* zipherx_tor_http_get(const char *url);

// Free a string allocated by Tor functions
void zipherx_tor_free_string(char *ptr);

// Check if Tor is available (compiled in)
bool zipherx_tor_is_available(void);

// =============================================================================
// Hidden Service (Onion Hosting)
// =============================================================================

// Start the hidden service (requires Tor to be connected)
// Returns 0 on success, 1 on error, 2 if already running
int32_t zipherx_tor_hidden_service_start(void);

// Stop the hidden service
// Returns 0 on success
int32_t zipherx_tor_hidden_service_stop(void);

// Get hidden service state
// 0 = Not running, 1 = Starting, 2 = Running, 3 = Error
uint8_t zipherx_tor_hidden_service_get_state(void);

// Get the .onion address of our hidden service
// Returns pointer to null-terminated string (caller must free with zipherx_tor_free_string)
// Returns NULL if hidden service is not running
char* zipherx_tor_hidden_service_get_address(void);

// Set callback for incoming P2P connections
// Callback signature: void(connection_id: u64, host_ptr: const char*, port: u16)
void zipherx_tor_hidden_service_set_callback(
    void (*callback)(uint64_t connection_id, const char *host_ptr, uint16_t port)
);

// Check if hidden service feature is available (compiled in)
bool zipherx_tor_hidden_service_is_available(void);

// =============================================================================
// Persistent Hidden Service Keypair (Fixed .onion Address)
// =============================================================================

// Generate a new Ed25519 keypair for hidden service
// Returns 64 bytes (32-byte secret + 32-byte public) into out_keypair buffer
// Returns 0 on success, 1 on error
int32_t zipherx_tor_generate_hs_keypair(uint8_t *out_keypair);

// Set the hidden service keypair (64 bytes: secret + public)
// This enables persistent .onion address across restarts
// Returns 0 on success, 1 on error
int32_t zipherx_tor_set_hs_keypair(const uint8_t *keypair, size_t len);

// Clear the stored keypair (next start will generate random address)
// Returns 0 on success
int32_t zipherx_tor_clear_hs_keypair(void);

// Check if a persistent keypair is set
// Returns 1 if set, 0 if not
int32_t zipherx_tor_has_hs_keypair(void);

// Get the .onion address from the stored keypair (without starting service)
// Returns pointer to null-terminated string (caller must free with zipherx_tor_free_string)
// Returns NULL if no keypair is set
char* zipherx_tor_get_keypair_onion_address(void);

// =============================================================================
// Cypherpunk Chat (Encrypted P2P Messaging over Tor)
// =============================================================================

// Set callback for incoming chat messages
// Callback signature: void(connection_id: u64, data_ptr: const u8*, data_len: usize)
void zipherx_tor_chat_set_callback(
    void (*callback)(uint64_t connection_id, const uint8_t *data_ptr, size_t data_len)
);

// Get the chat port for ZipherX encrypted messaging (8034)
uint16_t zipherx_tor_chat_get_port(void);

// Send an encrypted chat message to an .onion address
// The message should already be encrypted by the caller (X25519 + ChaCha20-Poly1305)
// Returns 0 on success, 1 on error
int32_t zipherx_tor_chat_send(
    const char *onion_address,
    const uint8_t *data,
    size_t data_len
);

// =============================================================================
// Library Info & Branch ID
// =============================================================================

/// Get library version (3 = with ZclassicButtercup support)
uint32_t zipherx_version(void);

/// Get the consensus branch ID for a given block height
/// Returns 0x930b540d for heights >= 707,000 (ZclassicButtercup)
uint32_t zipherx_get_branch_id(uint64_t height);

/// Verify the library supports ZclassicButtercup branch ID
/// Returns true if the library is built with the correct local fork
bool zipherx_verify_buttercup_support(void);

/// Get the number of CPU threads Rayon will use for parallel operations
size_t zipherx_get_rayon_threads(void);

/// FIX #1326: Real-time Groth16 proof progress (for UI countdown timer)
uint32_t zipherx_get_proof_total(void);
uint32_t zipherx_get_proof_completed(void);
uint32_t zipherx_get_proof_threads(void);

/// FIX #1328: Cancel in-progress Groth16 proof generation.
/// Sets atomic flag checked between proofs — prevents 900% CPU from concurrent sessions.
void zipherx_cancel_proof_generation(void);

// =============================================================================
// ZSTD Decompression
// =============================================================================

/// Decompress ZSTD-compressed data
/// Returns 1 on success, 0 on failure
/// Output buffer must be freed with zipherx_free_buffer
int32_t zipherx_zstd_decompress(
    const uint8_t *compressed_ptr,
    size_t compressed_len,
    uint8_t **out_ptr,
    size_t *out_len
);

/// FIX #1338: Streaming file-to-file ZSTD decompression (no memory loading)
/// Returns: 0 = success, 1 = invalid input, 2 = source error, 3 = dest error, 4 = decompress error
int32_t zipherx_zstd_decompress_file(
    const uint8_t *source_path_ptr,
    size_t source_path_len,
    const uint8_t *dest_path_ptr,
    size_t dest_path_len
);

/// Free a buffer allocated by Rust FFI
void zipherx_free_buffer(uint8_t *ptr);

// =============================================================================
// Utility Functions
// =============================================================================

/// Progress callback type for tree loading: (current, total)
typedef void (*TreeLoadProgressCallback)(uint64_t current, uint64_t total);

/// Compute double SHA256 hash
/// Returns true on success
bool zipherx_double_sha256(const uint8_t *input, size_t len, uint8_t *hash_out);

/// Compute value commitment
bool zipherx_compute_value_commitment(uint64_t value, const uint8_t *rcv, uint8_t *cv_out);

/// Generate random scalar (32 bytes)
bool zipherx_random_scalar(uint8_t *output);

/// Encrypt a note for transmission
bool zipherx_encrypt_note(
    const uint8_t *diversifier,   // 11 bytes
    const uint8_t *pk_d,          // 32 bytes
    uint64_t value,
    const uint8_t *rcm,           // 32 bytes
    const uint8_t *memo,          // 512 bytes
    uint8_t *epk_out,             // 32 bytes output
    uint8_t *enc_out              // 580 bytes output
);

/// Try to recover output with OVK (for viewing our own outgoing notes)
/// Returns recovered output length
size_t zipherx_try_recover_output_with_ovk(
    const uint8_t *ovk,            // 32 bytes
    const uint8_t *cv,             // 32 bytes
    const uint8_t *cmu,            // 32 bytes
    const uint8_t *epk,            // 32 bytes
    const uint8_t *enc_ciphertext, // 580 bytes
    const uint8_t *out_ciphertext, // 80 bytes
    uint8_t *output                // recovered output
);

/// Encode spending key as Bech32 string (secret-extended-key-main1...)
/// Returns length of encoded string
size_t zipherx_encode_spending_key(const uint8_t *sk, uint8_t *output);

/// Decode Bech32 spending key string to bytes
/// Returns true on success
bool zipherx_decode_spending_key(const char *addr_str, uint8_t *sk_out);

/// Validate a z-address
/// Returns true if valid
bool zipherx_validate_address(const char *addr_str);

/// Load witness from serialized data (1028 bytes)
/// Returns array index or u64::MAX on error
uint64_t zipherx_tree_load_witness(const uint8_t *witness_data, size_t witness_len);

/// FIX #1177: Get tree position from a loaded witness (for nullifier computation)
/// witness_index: Array index returned by zipherx_tree_load_witness
/// Returns tree position or u64::MAX on error
uint64_t zipherx_witness_get_tree_position(uint64_t witness_index);

/// FIX #739: Update ALL loaded witnesses with a CMU (WITHOUT modifying the tree)
/// Returns number of witnesses updated
uint64_t zipherx_update_all_witnesses_with_cmu(const uint8_t *cmu);

/// FIX #739: Batch update ALL loaded witnesses with multiple CMUs (WITHOUT modifying the tree)
/// cmus_data: Packed CMU data (32 bytes per CMU)
/// cmu_count: Number of CMUs to append
/// Returns number of witnesses fully updated
uint64_t zipherx_update_all_witnesses_batch(const uint8_t *cmus_data, size_t cmu_count);

/// FIX #739 v4: Get delta CMUs count from memory (not file)
uint64_t zipherx_get_delta_cmus_count(void);

/// FIX #739 v4: Get delta CMUs from memory (not file)
/// cmus_out: Output buffer for CMUs (32 bytes per CMU)
/// max_count: Maximum number of CMUs to return
/// Returns actual number of CMUs written
uint64_t zipherx_get_delta_cmus(uint8_t *cmus_out, size_t max_count);

/// Load commitment tree and create witnesses for multiple CMUs in one pass
/// Returns number of witnesses created
size_t zipherx_tree_load_with_witnesses(
    const uint8_t *cmu_data,
    size_t cmu_data_len,
    const uint8_t *target_cmus,
    size_t target_count,
    uint64_t *positions_out,
    uint8_t *witnesses_out,
    TreeLoadProgressCallback progress_callback
);

// =============================================================================
// FIX #982: CMU Consistency Verification (stored CMU vs computed CMU)
// =============================================================================

/// Verify that stored CMU matches computed CMU from note components
/// This is CRITICAL because FIX #838 uses stored CMU but Rust rebuilds note from parts
/// If they differ, anchor mismatch occurs → "joinsplit requirements not met"
/// Returns: 0=mismatch, 1=match, 2=error
uint32_t zipherx_verify_note_cmu(
    const uint8_t *stored_cmu,     // 32 bytes - CMU from database
    const uint8_t *diversifier,     // 11 bytes
    const uint8_t *rcm,             // 32 bytes
    uint64_t value,
    const uint8_t *spending_key     // 169 bytes
);

/// FIX #1138: Compute CMU from note parts - ROOT CAUSE FIX for P2P CMU mismatch
/// Returns computed CMU in cmu_out (32 bytes)
/// Returns: true on success, false on error
bool zipherx_compute_note_cmu(
    const uint8_t *diversifier,     // 11 bytes
    const uint8_t *rcm,             // 32 bytes
    uint64_t value,
    const uint8_t *spending_key,    // 169 bytes
    uint8_t *cmu_out                // 32 bytes output
);

// =============================================================================
// FIX #342: Fast HTTP Downloads (Rust reqwest - replaces slow Swift URLSession)
// =============================================================================

// Download a file with resume support
// Returns: 0=success, 1=network error, 2=file error, 3=cancelled, 4=other error
int32_t zipherx_download_file(
    const uint8_t *url_ptr,
    size_t url_len,
    const uint8_t *dest_path_ptr,
    size_t dest_path_len,
    uint64_t resume_from,
    uint64_t expected_size
);

// Get current download progress (thread-safe, call from Swift timer)
void zipherx_download_get_progress(
    uint64_t *bytes_downloaded,
    uint64_t *total_bytes,
    double *speed_bps
);

// Cancel current download
void zipherx_download_cancel(void);

// Verify SHA256 checksum of a file
// Returns: 1=match, 0=mismatch, -1=error
int32_t zipherx_verify_sha256(
    const uint8_t *file_path_ptr,
    size_t file_path_len,
    const uint8_t *expected_hash_ptr,
    size_t expected_hash_len
);

#endif // ZIPHERX_FFI_H
