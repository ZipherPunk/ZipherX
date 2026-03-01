//! Safe FFI wrappers and test constants for zipherx-ffi test suite
//!
//! Provides ergonomic Rust wrappers around the unsafe extern "C" functions
//! to eliminate boilerplate in test files.

extern crate zipherx_ffi;

use std::ffi::CString;

// ═══════════════════════════════════════════════════════════
// Test Constants (from existing test binaries)
// ═══════════════════════════════════════════════════════════

/// First CMU at Sapling activation (wire format, from test_first_cmu.rs)
pub const FIRST_CMU_WIRE_HEX: &str =
    "43391df0dc0983da7ad647a8cd4c3a2575dcccda3da44158ceef484ba7478d5a";

/// Expected tree root after appending first CMU (wire format)
/// Display format: 4fa518c5b25bb460710ba5e42d83b549100193abb5a895a20717dfeaf96116d4
pub const FIRST_CMU_ROOT_WIRE_HEX: &str =
    "d41661f9eadf1707a295a8b5ab93011049b5832de4a50b7160b45bb2c518a54f";

/// Known valid Zclassic z-address (from test_addr.rs)
pub const KNOWN_VALID_ADDRESS: &str =
    "zs1rvcpa07m7ezyww977ln9vx8pdvhqf7859rnq3h4q6j4d5yusegddpsgtcj5q097ychs9jjrf2p2";

/// Known valid 24-word BIP-39 mnemonic (all "abandon" + "art")
pub const KNOWN_VALID_MNEMONIC: &str =
    "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon art";

/// Block 2926123 header + varint + solution (543 bytes, from test_equihash.rs)
pub const BLOCK_2926123_HEX: &str = "04000000cdd5281549795ad06f25cd7aa60a12993fd3e3c253945f598753286160010000011bb896d54438cedfdb15e224bbb26c206c5b9031715b698c08692ba0ad01aefca643557e3a236e3f4c1c89e6d8e3ba7e1898a356df2cb5767438c6a9ba492af9882a69e7f6041e0419163cb9aabe3b4786d3439c803950f82855020000000000000000592bd5b1fd90010014c80f0592926736bc81261143a0a791e398df81908160355ac42d35e59c1e895697e119498f3f8cdefdd7abb575e206260b9b12293a4f44538b2a08f0e18984bd10bbf63126018467fd1e0d5bb0102bb450ec7f113442bea9d9b2b93fcafc8fe64b2315f39f8f3d3187e6de67f526c61a954d20b1dedda3d1cf70ec21e8c75b34dacdc57a12e57195d23c6fd51fae4069e547222628c824b36c655b4f17360b8f1359f573875819cd96476513082c7c1f65862f1491f76ec5ff659feedc5d481ee62b1bb4f0bc02cab19c2451e4f0e798612544446402ab22225effdd45491012c2803efdc2a88b3b1cb32052578f5f74e212bee521afb4e4034cd0ba0060cfc3e77a0c95445ea91fac86e30f3657a62b240ad369614c3bac51adda52c931e8887c3212f5f605ab2ae3eb036ec2c9cc0a4672d3cf0edd95716f7cd60ffdfb880d0f99340989f724e1fc94a3a83332f9c0b222a0b32f6533510dfeded10477365d0b46da6d76101388b2270b6459cfb4e1b273fce6190b8933e6b795e2b7b45950cd21f92214b411ace14202a814f8";

/// Buttercup branch ID (post height 707000)
pub const BUTTERCUP_BRANCH_ID: u32 = 0x930b540d;

// ═══════════════════════════════════════════════════════════
// Helper: hex decode
// ═══════════════════════════════════════════════════════════

/// Decode hex string to bytes
pub fn hex_decode(hex: &str) -> Vec<u8> {
    (0..hex.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&hex[i..i + 2], 16).unwrap())
        .collect()
}

/// Decode hex string to a fixed-size array
pub fn hex_to_array<const N: usize>(hex: &str) -> [u8; N] {
    let bytes = hex_decode(hex);
    assert_eq!(bytes.len(), N, "hex string length mismatch: expected {} bytes, got {}", N, bytes.len());
    let mut arr = [0u8; N];
    arr.copy_from_slice(&bytes);
    arr
}

/// Encode bytes to hex string
pub fn hex_encode(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{:02x}", b)).collect()
}

/// Parse varint from raw block data (Bitcoin-style)
pub fn parse_varint(data: &[u8]) -> (usize, usize) {
    let first = data[0];
    if first < 253 {
        (first as usize, 1)
    } else if first == 253 {
        let len = data[1] as usize | ((data[2] as usize) << 8);
        (len, 3)
    } else if first == 254 {
        let len = data[1] as usize
            | ((data[2] as usize) << 8)
            | ((data[3] as usize) << 16)
            | ((data[4] as usize) << 24);
        (len, 5)
    } else {
        panic!("Unsupported 8-byte varint");
    }
}

// ═══════════════════════════════════════════════════════════
// Key Derivation Wrappers
// ═══════════════════════════════════════════════════════════

/// Generate a 24-word BIP-39 mnemonic
pub fn generate_mnemonic() -> Option<String> {
    let mut buffer = vec![0u8; 512];
    let len = unsafe { zipherx_ffi::zipherx_generate_mnemonic(buffer.as_mut_ptr()) };
    if len == 0 {
        return None;
    }
    String::from_utf8(buffer[..len].to_vec()).ok()
}

/// Validate a BIP-39 mnemonic phrase
pub fn validate_mnemonic(phrase: &str) -> bool {
    let c_str = CString::new(phrase).unwrap();
    unsafe { zipherx_ffi::zipherx_validate_mnemonic(c_str.as_ptr()) }
}

/// Derive 64-byte seed from mnemonic (PBKDF2-SHA512)
pub fn mnemonic_to_seed(phrase: &str) -> Option<[u8; 64]> {
    let c_str = CString::new(phrase).unwrap();
    let mut seed = [0u8; 64];
    let ok = unsafe { zipherx_ffi::zipherx_mnemonic_to_seed(c_str.as_ptr(), seed.as_mut_ptr()) };
    if ok {
        Some(seed)
    } else {
        None
    }
}

/// Derive 169-byte ExtendedSpendingKey from seed
pub fn derive_spending_key(seed: &[u8; 64], account: u32) -> Option<[u8; 169]> {
    let mut sk = [0u8; 169];
    let ok = unsafe {
        zipherx_ffi::zipherx_derive_spending_key(seed.as_ptr(), account, sk.as_mut_ptr())
    };
    if ok {
        Some(sk)
    } else {
        None
    }
}

/// Derive 43-byte payment address from spending key
pub fn derive_address(sk: &[u8; 169], diversifier_index: u64) -> Option<([u8; 43], u64)> {
    let mut addr = [0u8; 43];
    let mut actual_index: u64 = 0;
    let ok = unsafe {
        zipherx_ffi::zipherx_derive_address(
            sk.as_ptr(),
            diversifier_index,
            addr.as_mut_ptr(),
            &mut actual_index as *mut u64,
        )
    };
    if ok {
        Some((addr, actual_index))
    } else {
        None
    }
}

/// Derive 32-byte incoming viewing key from spending key
pub fn derive_ivk(sk: &[u8; 169]) -> Option<[u8; 32]> {
    let mut ivk = [0u8; 32];
    let ok = unsafe { zipherx_ffi::zipherx_derive_ivk(sk.as_ptr(), ivk.as_mut_ptr()) };
    if ok {
        Some(ivk)
    } else {
        None
    }
}

/// Derive 32-byte outgoing viewing key from spending key
pub fn derive_ovk(sk: &[u8; 169]) -> Option<[u8; 32]> {
    let mut ovk = [0u8; 32];
    let ok = unsafe { zipherx_ffi::zipherx_derive_ovk(sk.as_ptr(), ovk.as_mut_ptr()) };
    if ok {
        Some(ovk)
    } else {
        None
    }
}

// ═══════════════════════════════════════════════════════════
// Address Wrappers
// ═══════════════════════════════════════════════════════════

/// Encode 43-byte address to bech32 z-address string
pub fn encode_address(addr_bytes: &[u8; 43]) -> Option<String> {
    let mut output = vec![0u8; 256];
    let len =
        unsafe { zipherx_ffi::zipherx_encode_address(addr_bytes.as_ptr(), output.as_mut_ptr()) };
    if len == 0 {
        return None;
    }
    String::from_utf8(output[..len].to_vec()).ok()
}

/// Decode bech32 z-address string to 43 bytes
pub fn decode_address(addr_str: &str) -> Option<[u8; 43]> {
    let c_str = CString::new(addr_str).unwrap();
    let mut output = [0u8; 43];
    let ok =
        unsafe { zipherx_ffi::zipherx_decode_address(c_str.as_ptr(), output.as_mut_ptr()) };
    if ok {
        Some(output)
    } else {
        None
    }
}

/// Validate a bech32 z-address string
pub fn validate_address(addr_str: &str) -> bool {
    let c_str = CString::new(addr_str).unwrap();
    unsafe { zipherx_ffi::zipherx_validate_address(c_str.as_ptr()) }
}

// ═══════════════════════════════════════════════════════════
// Key Encoding Wrappers
// ═══════════════════════════════════════════════════════════

/// Encode spending key to bech32 string
pub fn encode_spending_key(sk: &[u8; 169]) -> Option<String> {
    let mut output = vec![0u8; 512];
    let len = unsafe {
        zipherx_ffi::zipherx_encode_spending_key(sk.as_ptr(), output.as_mut_ptr())
    };
    if len == 0 {
        return None;
    }
    String::from_utf8(output[..len].to_vec()).ok()
}

/// Decode bech32 spending key string to 169 bytes
pub fn decode_spending_key(encoded: &str) -> Option<[u8; 169]> {
    let c_str = CString::new(encoded).unwrap();
    let mut output = [0u8; 169];
    let ok = unsafe {
        zipherx_ffi::zipherx_decode_spending_key(c_str.as_ptr(), output.as_mut_ptr())
    };
    if ok {
        Some(output)
    } else {
        None
    }
}

// ═══════════════════════════════════════════════════════════
// Tree Operation Wrappers
// ═══════════════════════════════════════════════════════════

/// Initialize empty commitment tree
pub fn tree_init() -> bool {
    zipherx_ffi::zipherx_tree_init()
}

/// Get current tree size (number of commitments)
pub fn tree_size() -> u64 {
    zipherx_ffi::zipherx_tree_size()
}

/// Append a single 32-byte CMU (wire format), returns position or None
pub fn tree_append(cmu: &[u8; 32]) -> Option<u64> {
    let pos = unsafe { zipherx_ffi::zipherx_tree_append(cmu.as_ptr()) };
    if pos == u64::MAX {
        None
    } else {
        Some(pos)
    }
}

/// Append a batch of CMUs (each 32 bytes), returns last position or None
pub fn tree_append_batch(cmus: &[[u8; 32]]) -> Option<u64> {
    if cmus.is_empty() {
        return None;
    }
    let pos = unsafe {
        zipherx_ffi::zipherx_tree_append_batch(cmus[0].as_ptr(), cmus.len())
    };
    if pos == u64::MAX {
        None
    } else {
        Some(pos)
    }
}

/// Get tree root as 32 bytes (wire format)
pub fn tree_root() -> Option<[u8; 32]> {
    let mut root = [0u8; 32];
    let ok = unsafe { zipherx_ffi::zipherx_tree_root(root.as_mut_ptr()) };
    if ok {
        Some(root)
    } else {
        None
    }
}

/// Serialize tree to bytes. Returns (data, length) or None.
pub fn tree_serialize() -> Option<Vec<u8>> {
    let mut buffer = vec![0u8; 20_000_000]; // 20MB max
    let mut len: usize = 0;
    let ok = unsafe {
        zipherx_ffi::zipherx_tree_serialize(buffer.as_mut_ptr(), &mut len as *mut usize)
    };
    if ok && len > 0 {
        buffer.truncate(len);
        Some(buffer)
    } else {
        None
    }
}

/// Deserialize tree from bytes
pub fn tree_deserialize(data: &[u8]) -> bool {
    unsafe { zipherx_ffi::zipherx_tree_deserialize(data.as_ptr(), data.len()) }
}

/// Load tree from bundled CMU format [count: u64 LE][cmu1: 32][cmu2: 32]...
pub fn tree_load_from_cmus(data: &[u8]) -> bool {
    unsafe { zipherx_ffi::zipherx_tree_load_from_cmus(data.as_ptr(), data.len()) }
}

// ═══════════════════════════════════════════════════════════
// Witness Wrappers
// ═══════════════════════════════════════════════════════════

/// Clear all witnesses, returns count cleared
pub fn witnesses_clear() -> u64 {
    zipherx_ffi::zipherx_witnesses_clear()
}

/// Get witness count
pub fn witness_current() -> u64 {
    zipherx_ffi::zipherx_tree_witness_current()
}

/// Get serialized witness (1028 bytes, zero-padded)
pub fn tree_get_witness(witness_index: u64) -> Option<[u8; 1028]> {
    let mut buffer = [0u8; 1028];
    let ok = unsafe {
        zipherx_ffi::zipherx_tree_get_witness(witness_index, buffer.as_mut_ptr())
    };
    if ok {
        Some(buffer)
    } else {
        None
    }
}

/// Get witness root (32 bytes)
pub fn witness_get_root(witness_data: &[u8]) -> Option<[u8; 32]> {
    let mut root = [0u8; 32];
    let ok = unsafe {
        zipherx_ffi::zipherx_witness_get_root(
            witness_data.as_ptr(),
            witness_data.len(),
            root.as_mut_ptr(),
        )
    };
    if ok {
        Some(root)
    } else {
        None
    }
}

/// Check if witness merkle path is valid
pub fn witness_path_is_valid(witness_data: &[u8]) -> bool {
    unsafe {
        zipherx_ffi::zipherx_witness_path_is_valid(witness_data.as_ptr(), witness_data.len())
    }
}

/// Load a witness from serialized data. Returns witness index or u64::MAX on failure.
pub fn tree_load_witness(witness_data: &[u8]) -> Option<u64> {
    let result = unsafe {
        zipherx_ffi::zipherx_tree_load_witness(witness_data.as_ptr(), witness_data.len())
    };
    if result == u64::MAX {
        None
    } else {
        Some(result)
    }
}

/// Update all witnesses with a batch of CMUs
pub fn update_all_witnesses_batch(cmus: &[[u8; 32]]) -> u64 {
    if cmus.is_empty() {
        return 0;
    }
    unsafe {
        zipherx_ffi::zipherx_update_all_witnesses_batch(cmus[0].as_ptr(), cmus.len())
    }
}

// ═══════════════════════════════════════════════════════════
// Equihash / Header Wrappers
// ═══════════════════════════════════════════════════════════

/// Verify Equihash solution
pub fn verify_equihash(header: &[u8], solution: &[u8]) -> bool {
    unsafe {
        zipherx_ffi::zipherx_verify_equihash(
            header.as_ptr(),
            solution.as_ptr(),
            solution.len(),
        )
    }
}

/// Compute block hash (double SHA256)
pub fn compute_block_hash(header: &[u8], solution: &[u8]) -> Option<[u8; 32]> {
    let mut hash = [0u8; 32];
    let ok = unsafe {
        zipherx_ffi::zipherx_compute_block_hash(
            header.as_ptr(),
            solution.as_ptr(),
            solution.len(),
            hash.as_mut_ptr(),
        )
    };
    if ok {
        Some(hash)
    } else {
        None
    }
}

// ═══════════════════════════════════════════════════════════
// Utility Wrappers
// ═══════════════════════════════════════════════════════════

/// Compute double SHA256
pub fn double_sha256(data: &[u8]) -> Option<[u8; 32]> {
    let mut output = [0u8; 32];
    let ok = unsafe {
        zipherx_ffi::zipherx_double_sha256(data.as_ptr(), data.len(), output.as_mut_ptr())
    };
    if ok {
        Some(output)
    } else {
        None
    }
}

/// Generate a random jubjub scalar (32 bytes)
pub fn random_scalar() -> Option<[u8; 32]> {
    let mut output = [0u8; 32];
    let ok = unsafe { zipherx_ffi::zipherx_random_scalar(output.as_mut_ptr()) };
    if ok {
        Some(output)
    } else {
        None
    }
}

/// Compute nullifier for a note
pub fn compute_nullifier(
    spending_key: &[u8; 169],
    diversifier: &[u8; 11],
    value: u64,
    rcm: &[u8; 32],
    position: u64,
) -> Option<[u8; 32]> {
    let mut nf = [0u8; 32];
    let ok = unsafe {
        zipherx_ffi::zipherx_compute_nullifier(
            spending_key.as_ptr(),
            diversifier.as_ptr(),
            value,
            rcm.as_ptr(),
            position,
            nf.as_mut_ptr(),
        )
    };
    if ok {
        Some(nf)
    } else {
        None
    }
}

/// Get delta CMU count
pub fn get_delta_cmus_count() -> u64 {
    zipherx_ffi::zipherx_get_delta_cmus_count()
}
