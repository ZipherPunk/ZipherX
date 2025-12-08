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
// SQLCipher - Encrypted Database Support
// =============================================================================
// SQLCipher provides transparent 256-bit AES encryption of the SQLite database.
// NOTE: We do NOT include sqlite3.h here to avoid module conflicts.
// Instead, we manually declare the SQLite3/SQLCipher functions we need.

// Core SQLite types
typedef struct sqlite3 sqlite3;
typedef struct sqlite3_stmt sqlite3_stmt;

// Result codes
#define SQLITE_OK           0
#define SQLITE_ERROR        1
#define SQLITE_ROW          100
#define SQLITE_DONE         101
#define SQLITE_NOTADB       26

// Open flags
#define SQLITE_OPEN_READWRITE     0x00000002
#define SQLITE_OPEN_CREATE        0x00000004
#define SQLITE_OPEN_FULLMUTEX     0x00010000

// Core SQLite functions (these are provided by libsqlcipher.a)
int sqlite3_open(const char *filename, sqlite3 **ppDb);
int sqlite3_open_v2(const char *filename, sqlite3 **ppDb, int flags, const char *zVfs);
int sqlite3_close(sqlite3 *);
int sqlite3_exec(sqlite3*, const char *sql, int (*callback)(void*,int,char**,char**), void *, char **errmsg);
void sqlite3_free(void*);
int sqlite3_prepare_v2(sqlite3 *db, const char *zSql, int nByte, sqlite3_stmt **ppStmt, const char **pzTail);
int sqlite3_step(sqlite3_stmt*);
int sqlite3_finalize(sqlite3_stmt *pStmt);
int sqlite3_reset(sqlite3_stmt *pStmt);
int sqlite3_bind_blob(sqlite3_stmt*, int, const void*, int n, void(*)(void*));
int sqlite3_bind_int(sqlite3_stmt*, int, int);
int sqlite3_bind_int64(sqlite3_stmt*, int, long long);
int sqlite3_bind_text(sqlite3_stmt*, int, const char*, int n, void(*)(void*));
int sqlite3_bind_null(sqlite3_stmt*, int);
int sqlite3_bind_double(sqlite3_stmt*, int, double);
double sqlite3_column_double(sqlite3_stmt*, int iCol);
const void *sqlite3_column_blob(sqlite3_stmt*, int iCol);
int sqlite3_column_bytes(sqlite3_stmt*, int iCol);
int sqlite3_column_int(sqlite3_stmt*, int iCol);
long long sqlite3_column_int64(sqlite3_stmt*, int iCol);
const unsigned char *sqlite3_column_text(sqlite3_stmt*, int iCol);
int sqlite3_column_type(sqlite3_stmt*, int iCol);
int sqlite3_column_count(sqlite3_stmt *pStmt);
int sqlite3_errcode(sqlite3 *db);
const char *sqlite3_errmsg(sqlite3*);
long long sqlite3_last_insert_rowid(sqlite3*);
int sqlite3_changes(sqlite3*);
int sqlite3_clear_bindings(sqlite3_stmt*);
const char *sqlite3_libversion(void);

// Destructor type
typedef void (*sqlite3_destructor_type)(void*);

// Destructor constants
#define SQLITE_STATIC      ((sqlite3_destructor_type)0)
#define SQLITE_TRANSIENT   ((sqlite3_destructor_type)-1)

// Column types
#define SQLITE_INTEGER  1
#define SQLITE_FLOAT    2
#define SQLITE_BLOB     4
#define SQLITE_NULL     5
#define SQLITE_TEXT     3

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
// Parallel Note Decryption (Rayon-based, ~6.7x speedup)
// =============================================================================

/// Batch decrypt multiple shielded outputs in parallel using Rayon
/// Input format (per output, 644 bytes): epk(32) + cmu(32) + ciphertext(580)
/// Output format (per output, 564 bytes): found(1) + diversifier(11) + value(8) + rcm(32) + memo(512)
/// @param sk 169-byte spending key
/// @param outputs_data Packed array of outputs (644 bytes each)
/// @param output_count Number of outputs to process
/// @param height Block height for version byte validation
/// @param results Output buffer (564 bytes per output)
/// @return Number of successfully decrypted notes
size_t zipherx_try_decrypt_notes_parallel(const uint8_t *sk,
                                           const uint8_t *outputs_data,
                                           size_t output_count,
                                           uint64_t height,
                                           uint8_t *results);

/// Get the number of CPU threads Rayon will use for parallel decryption
size_t zipherx_get_rayon_threads(void);

// =============================================================================
// Utility Functions
// =============================================================================

/// Get library version
/// @return Version number (3 = with Buttercup support)
uint32_t zipherx_version(void);

/// Get the consensus branch ID for a given height on Zclassic
/// @param height Block height
/// @return Branch ID as u32 (e.g., 0x930b540d for Buttercup at height >= 707000)
uint32_t zipherx_get_branch_id(uint64_t height);

/// Verify the library is using the correct ZclassicButtercup fork
/// @return true if using local fork with Buttercup support (0x930b540d)
bool zipherx_verify_buttercup_support(void);

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

/// Initialize the prover with Sapling parameters from file paths
/// NOTE: May fail on macOS with Hardened Runtime - use zipherx_init_prover_from_bytes instead
/// @param spend_path Path to sapling-spend.params
/// @param output_path Path to sapling-output.params
/// @return true on success
bool zipherx_init_prover(const char *spend_path, const char *output_path);

/// Initialize the prover with Sapling parameters from raw byte arrays
/// Use this when file access from Rust is restricted (e.g., Hardened Runtime)
/// @param spend_data Pointer to spend params bytes
/// @param spend_len Length of spend params (47958396 bytes)
/// @param output_data Pointer to output params bytes
/// @param output_len Length of output params (3592860 bytes)
/// @return true on success
bool zipherx_init_prover_from_bytes(const uint8_t *spend_data, size_t spend_len,
                                     const uint8_t *output_data, size_t output_len);

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
                                uint64_t chain_height,
                                uint8_t *tx_out,
                                size_t *tx_out_len);

/// Spend information for multi-input transactions
typedef struct {
    const uint8_t *witness_data;    // Serialized IncrementalWitness data
    size_t witness_len;              // Length of witness data
    uint64_t note_value;             // Note value in zatoshis
    const uint8_t *note_rcm;         // Note commitment randomness (32 bytes)
    const uint8_t *note_diversifier; // Note diversifier (11 bytes)
} SpendInfo;

/// Build a shielded transaction with multiple input notes
/// @param sk Extended spending key (169 bytes)
/// @param to_address Destination address bytes (43 bytes)
/// @param amount Amount to send in zatoshis
/// @param memo Optional memo (512 bytes, can be NULL)
/// @param spends Array of SpendInfo pointers
/// @param spend_count Number of spends
/// @param chain_height Current chain height (for branch ID selection)
/// @param tx_out Output buffer for transaction (at least 10000 bytes)
/// @param tx_out_len Output for transaction length
/// @param nullifiers_out Output buffer for nullifiers (32 bytes * spend_count)
/// @return true on success
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

// =============================================================================
// Commitment Tree Functions
// =============================================================================

/// Initialize a new empty Sapling commitment tree
/// @return true on success
bool zipherx_tree_init(void);

/// Append a note commitment to the tree
/// @param cmu 32-byte note commitment
/// @return Position of the added commitment, or UINT64_MAX on error
uint64_t zipherx_tree_append(const uint8_t *cmu);

/// Batch append multiple CMUs to the tree (MUCH faster than individual appends)
/// @param cmus_data Packed CMU data (32 bytes per CMU, in wire format)
/// @param cmu_count Number of CMUs to append
/// @return Starting position of the first CMU, or UINT64_MAX on error
uint64_t zipherx_tree_append_batch(const uint8_t *cmus_data, size_t cmu_count);

/// Create a witness for the current position
/// @return Witness index, or UINT64_MAX on error
uint64_t zipherx_tree_witness_current(void);

/// Load a witness from saved data into memory for updating
/// @param witness_data Saved witness data (1028 bytes)
/// @param witness_len Length of witness data
/// @return Witness index, or UINT64_MAX on error
uint64_t zipherx_tree_load_witness(const uint8_t *witness_data, size_t witness_len);

/// Get the current tree root
/// @param root_out Buffer for 32-byte root
/// @return true on success
bool zipherx_tree_root(uint8_t *root_out);

/// Get witness data for a specific index
/// @param witness_index Index from tree_witness_current
/// @param witness_out Buffer for 1028 bytes (4 pos + 32*32 path)
/// @return true on success
bool zipherx_tree_get_witness(uint64_t witness_index, uint8_t *witness_out);

/// Get current tree size
/// @return Number of commitments in tree
uint64_t zipherx_tree_size(void);

/// Serialize tree state for persistence
/// @param tree_out Buffer for serialized data
/// @param tree_out_len Output for actual length
/// @return true on success
bool zipherx_tree_serialize(uint8_t *tree_out, size_t *tree_out_len);

/// Deserialize tree state from persistence
/// @param tree_data Serialized tree data
/// @param tree_len Length of data
/// @return true on success
bool zipherx_tree_deserialize(const uint8_t *tree_data, size_t tree_len);

/// Load tree from raw CMUs file format
/// Format: [count: u64 LE][cmu1: 32 bytes][cmu2: 32 bytes]...
/// @param data CMU file data
/// @param data_len Length of data
/// @return true on success
bool zipherx_tree_load_from_cmus(const uint8_t *data, size_t data_len);

/// Progress callback type for tree loading: (current, total)
typedef void (*TreeLoadProgressCallback)(uint64_t current, uint64_t total);

/// Load tree from raw CMUs file format with progress callback
/// @param data CMU file data
/// @param data_len Length of data
/// @param progress_callback Callback called with (current, total) during loading
/// @return true on success
bool zipherx_tree_load_from_cmus_with_progress(
    const uint8_t *data,
    size_t data_len,
    TreeLoadProgressCallback progress_callback
);

/// Create a witness for a specific CMU from bundled CMU data
/// This is used for notes discovered in PHASE 1 (parallel scan) within bundled tree range
/// @param cmu_data Pointer to bundled CMU file data [count: u64][cmu1: 32]...
/// @param cmu_data_len Length of CMU data
/// @param target_cmu The 32-byte CMU to create witness for
/// @param witness_out Output buffer for serialized witness (at least 2000 bytes)
/// @param witness_out_len Output for actual witness length
/// @return The position (0-indexed) of the CMU, or UINT64_MAX on error
uint64_t zipherx_tree_create_witness_for_cmu(
    const uint8_t *cmu_data,
    size_t cmu_data_len,
    const uint8_t *target_cmu,
    uint8_t *witness_out,
    size_t *witness_out_len
);

/// Find the position of a CMU in bundled CMU data (fast binary search, no tree building)
/// @param cmu_data Pointer to bundled CMU file data [count: u64][cmu1: 32]...
/// @param cmu_data_len Length of CMU data
/// @param target_cmu The 32-byte CMU to find
/// @return The position (0-indexed) of the CMU, or UINT64_MAX if not found
uint64_t zipherx_find_cmu_position(
    const uint8_t *cmu_data,
    size_t cmu_data_len,
    const uint8_t *target_cmu
);

/// Create witnesses for MULTIPLE CMUs in a SINGLE tree pass (batch operation)
/// Much faster than calling zipherx_tree_create_witness_for_cmu multiple times
/// because it only builds the tree ONCE instead of N times.
///
/// @param cmu_data Bundled CMU file [count: u64][cmu1: 32]...
/// @param cmu_data_len Length of CMU data
/// @param target_cmus Array of 32-byte CMUs to create witnesses for
/// @param target_count Number of target CMUs
/// @param positions_out Output array for positions (u64 * target_count)
/// @param witnesses_out Output array for witnesses (1028 bytes * target_count)
/// @return Number of witnesses successfully created
size_t zipherx_tree_create_witnesses_batch(
    const uint8_t *cmu_data,
    size_t cmu_data_len,
    const uint8_t *target_cmus,
    size_t target_count,
    uint64_t *positions_out,
    uint8_t *witnesses_out
);

/// Create witnesses for MULTIPLE CMUs using PARALLEL processing (Rayon)
/// This is the FASTEST option - uses all CPU cores via Rayon work-stealing.
/// Each witness gets its own thread building tree to that position.
/// @param target_cmus Array of 32-byte CMUs to create witnesses for
/// @param target_count Number of target CMUs
/// @param cmu_data Bundled CMU file [count: u64][cmu1: 32]...
/// @param cmu_data_len Length of CMU data
/// @param positions_out Output array for positions (u64 * target_count)
/// @param witnesses_out Output array for witnesses (1028 bytes * target_count)
/// @return Number of witnesses successfully created
size_t zipherx_tree_create_witnesses_parallel(
    const uint8_t *target_cmus,
    size_t target_count,
    const uint8_t *cmu_data,
    size_t cmu_data_len,
    uint64_t *positions_out,
    uint8_t *witnesses_out
);

/// Extract the Merkle root (anchor) from a serialized witness
/// @param witness_data Serialized witness (1028 bytes from treeCreateWitnessesBatch)
/// @param witness_len Length of witness data
/// @param root_out 32-byte output buffer for the root
/// @return true if successful
bool zipherx_witness_get_root(
    const uint8_t *witness_data,
    size_t witness_len,
    uint8_t *root_out
);

// =============================================================================
// OVK Output Recovery (for viewing sent transactions)
// =============================================================================

/// Try to recover a sent note using the outgoing viewing key
/// @param ovk 32-byte outgoing viewing key
/// @param cv 32-byte value commitment
/// @param cmu 32-byte note commitment
/// @param epk 32-byte ephemeral public key
/// @param enc_ciphertext 580-byte encrypted ciphertext
/// @param out_ciphertext 80-byte output ciphertext
/// @param output Buffer for result (at least 620 bytes)
/// @return Length of output on success, 0 on failure
size_t zipherx_try_recover_output_with_ovk(const uint8_t *ovk,
                                            const uint8_t *cv,
                                            const uint8_t *cmu,
                                            const uint8_t *epk,
                                            const uint8_t *enc_ciphertext,
                                            const uint8_t *out_ciphertext,
                                            uint8_t *output);

/// Derive OVK from extended spending key
/// @param sk 169-byte extended spending key
/// @param ovk_out Buffer for 32-byte OVK
/// @return true on success
bool zipherx_derive_ovk(const uint8_t *sk, uint8_t *ovk_out);

// =============================================================================
// Equihash Proof-of-Work Verification (trustless header validation)
// =============================================================================

/// Verify Equihash(200,9) solution for a block header
/// @param header_bytes 140-byte block header (includes 32-byte nonce at end)
/// @param solution Equihash solution bytes (typically 1344 bytes)
/// @param solution_len Length of solution
/// @return true if solution is valid
bool zipherx_verify_equihash(const uint8_t *header_bytes,
                              const uint8_t *solution,
                              size_t solution_len);

/// Compute block hash (double SHA256) from header + solution
/// @param header_bytes 140-byte block header
/// @param solution Equihash solution bytes
/// @param solution_len Length of solution
/// @param hash_out Output buffer for 32-byte hash (internal byte order)
/// @return true on success
bool zipherx_compute_block_hash(const uint8_t *header_bytes,
                                 const uint8_t *solution,
                                 size_t solution_len,
                                 uint8_t *hash_out);

/// Verify a chain of block headers for continuity and valid PoW
/// @param headers_data Concatenated header data (140 bytes + varint + solution each)
/// @param headers_count Number of headers
/// @param expected_prev_hash Expected prevHash of first header (32 bytes), or NULL
/// @param header_offsets Array of byte offsets for each header
/// @param header_sizes Array of total sizes for each header
/// @return true if all headers valid and chain is continuous
bool zipherx_verify_header_chain(const uint8_t *headers_data,
                                  size_t headers_count,
                                  const uint8_t *expected_prev_hash,
                                  const size_t *header_offsets,
                                  const size_t *header_sizes);

/// Verify a single block header and get its hash
/// @param header_and_solution Full header data (140 bytes + varint + solution)
/// @param total_len Total length of data
/// @param hash_out Output buffer for 32-byte block hash
/// @return true if header is valid
bool zipherx_verify_block_header(const uint8_t *header_and_solution,
                                  size_t total_len,
                                  uint8_t *hash_out);

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

/// Build a shielded transaction using an encrypted spending key (VUL-002 secure)
/// The spending key is decrypted only within Rust and zeroed after use
/// @param encrypted_sk 197-byte AES-GCM encrypted spending key (nonce + ciphertext + tag)
/// @param encrypted_sk_len Length of encrypted key (should be 197)
/// @param encryption_key 32-byte AES-256 key for decryption
/// @param to_address Destination address bytes (43 bytes)
/// @param amount Amount in zatoshis
/// @param memo Optional memo (512 bytes)
/// @param anchor Merkle tree anchor (32 bytes)
/// @param witness_data Serialized witness
/// @param witness_len Length of witness data
/// @param note_value Value of note being spent
/// @param note_rcm Note randomness (32 bytes)
/// @param note_diversifier Note diversifier (11 bytes)
/// @param chain_height Current chain height
/// @param tx_out Output buffer for transaction (at least 10000 bytes)
/// @param tx_out_len Output for transaction length
/// @return true on success
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

/// Build a shielded transaction with multiple inputs using encrypted spending key (VUL-002 secure)
/// The spending key is decrypted only within Rust and zeroed after use
/// @param encrypted_sk 197-byte AES-GCM encrypted spending key
/// @param encrypted_sk_len Length of encrypted key (should be 197)
/// @param encryption_key 32-byte AES-256 key for decryption
/// @param to_address Destination address bytes (43 bytes)
/// @param amount Amount to send in zatoshis
/// @param memo Optional memo (512 bytes, can be NULL)
/// @param spends Array of SpendInfo pointers
/// @param spend_count Number of spends
/// @param chain_height Current chain height
/// @param tx_out Output buffer for transaction (at least 10000 bytes)
/// @param tx_out_len Output for transaction length
/// @param nullifiers_out Output buffer for nullifiers (32 bytes * spend_count)
/// @return true on success
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

/// Result for a discovered note from boost file scanning
/// Contains all data needed to store in database and build transactions
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

/// Summary result from boost scan
typedef struct {
    uint64_t total_received;   // Total value of all notes found
    uint64_t total_spent;      // Total value of spent notes
    uint64_t unspent_balance;  // Final spendable balance
    uint32_t notes_found;      // Number of notes found
    uint32_t notes_spent;      // Number of notes that are spent
    uint32_t spends_checked;   // Number of spends in boost file
} BoostScanResult;

/// Scan boost file outputs section and return discovered notes with nullifiers
/// Performs complete PHASE 1 + PHASE 1.6 scanning in Rust:
/// 1. Parse outputs from boost data (652 bytes per output)
/// 2. Parse spends from boost data (36 bytes per spend)
/// 3. Parallel note decryption using Rayon
/// 4. Compute nullifiers for each discovered note
/// 5. Check nullifiers against spends to detect spent notes
///
/// Returns: Number of notes written to notes_out
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
// Tor (Arti) Integration - Embedded Tor for iOS and macOS
// =============================================================================

/// Start the embedded Tor client (Arti)
/// Returns 0 on success, 1 on error
int32_t zipherx_tor_start(void);

/// Stop the Tor client
/// Returns 0 on success
int32_t zipherx_tor_stop(void);

/// Get current Tor state
/// 0 = Disconnected, 1 = Connecting, 2 = Bootstrapping, 3 = Connected, 4 = Error
uint8_t zipherx_tor_get_state(void);

/// Get bootstrap progress (0-100)
uint8_t zipherx_tor_get_progress(void);

/// Get SOCKS proxy port (0 if not connected)
uint16_t zipherx_tor_get_socks_port(void);

/// Get last error message
/// Returns pointer to null-terminated string (caller must free with zipherx_tor_free_string)
char* zipherx_tor_get_error(void);

/// Request new Tor identity (new circuit)
/// Returns 0 on success
int32_t zipherx_tor_new_identity(void);

/// Make an HTTP GET request through Tor
/// Returns response body as null-terminated string (caller must free with zipherx_tor_free_string)
/// Returns NULL on error
char* zipherx_tor_http_get(const char *url);

/// Free a string allocated by Tor functions
void zipherx_tor_free_string(char *ptr);

/// Check if Tor is available (compiled in)
bool zipherx_tor_is_available(void);

#endif /* ZipherX_Bridging_Header_h */
