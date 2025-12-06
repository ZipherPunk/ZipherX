//! Test Equihash verification with real Zclassic block 2930000
//! This verifies we're using the correct parameters (200, 9)

fn main() {
    // Block 2930000 raw data (first ~1500 bytes containing header + solution)
    // Header is 140 bytes, then varint for solution length, then 1344-byte solution
    let raw_hex = "04000000bc51189e13303d4a7a3fedb097a7cf5e0a5b0da6e0ed65f5a9a3cd0a27000000bf042b8c438477460538240679bb6575c55ae9c1b5d380867b872cc784ab42c23c23051912a48a45125da07a2b3858b5b9bef1c1c58e21de7e74aa93f3b7c731fb102f694e05051e035a6705e46d35e8185d02e43bf47ef1d235eb570000000000000000ba53240cfd9001004dc9840b9a1ceec49ab775e0e7084c0e8ba8ad9f56e5661908cc6a783ccead220916cca220911f19ed3acd1aa45b20b34e016d752feb864de20e6d6eba496a818efec47b7fff29f9af7a0c0c7d07bcd046aeeb5ede2911c6e241eebf5a1fbe89a4ad4303d94ec5c14503bf28d60e89baa42e97d6875721c9f9e484a3061ed87f3bc9e80703d47ffe08da6d3647c2d344b045f66e9c0da972ff8df262e0fad3a29cc1fb8e43f22481df639ba9e97d21d4249def5b28238a5b23e96a8c993e7171a392d947e1000401762a988e2d973fa5d5ec47089670a6915cab1114b9d2964c3150a57bab340ee94e6bf2d746069f8639db298d11b0fd1440173435203abd0798e6d6e3af16aff8f565bd0e7a6ddb6f9e503f2d0beb91c19e5fc2b206f8494cca8dc2333f40fc2ff64a08089855f5e0d81a82cc0f169864584d2d7e1d3e01ffd97953d50c632b95fb76c36bc478f8f7f5e254f696f14e74df8b4887e50e91c475b5c67333c4d9fb8e618249a4e649a089976b8b7274264d1b97346925d0b1f4773de63f51dd99267a1270d717803b010400008085202f89010000000000000000000000000000000000000000000000000000000000000000ffffffff050350b52c00ffffffff01e40b5402000000001976a9143b6d35a8b95908ba839d50dc0b7797f0fa4eb23e88ac00000000000000000000000000000000000000";

    // Parse the hex
    let raw_bytes: Vec<u8> = (0..raw_hex.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&raw_hex[i..i+2], 16).unwrap())
        .collect();

    println!("=== Zclassic Block 2930000 Equihash Test ===");
    println!("Raw data length: {} bytes", raw_bytes.len());

    // Extract header (140 bytes)
    let header = &raw_bytes[0..140];
    println!("Header: {} bytes", header.len());

    // Parse solution length varint at offset 140
    let varint_byte = raw_bytes[140];
    let (solution_len, varint_size) = if varint_byte < 253 {
        (varint_byte as usize, 1)
    } else if varint_byte == 253 {
        let len = raw_bytes[141] as usize | ((raw_bytes[142] as usize) << 8);
        (len, 3)
    } else if varint_byte == 254 {
        let len = raw_bytes[141] as usize
            | ((raw_bytes[142] as usize) << 8)
            | ((raw_bytes[143] as usize) << 16)
            | ((raw_bytes[144] as usize) << 24);
        (len, 5)
    } else {
        panic!("Unsupported varint size");
    };

    println!("Varint byte: 0x{:02x} (decimal: {})", varint_byte, varint_byte);
    println!("Solution length from varint: {} bytes", solution_len);
    println!("Expected for Equihash(192,7): 400 bytes");

    // Extract solution
    let solution_start = 140 + varint_size;
    if solution_start + solution_len > raw_bytes.len() {
        println!("❌ Not enough data for solution! Need {} more bytes",
                 (solution_start + solution_len) - raw_bytes.len());
        return;
    }
    let solution = &raw_bytes[solution_start..solution_start + solution_len];

    println!("Solution actual length: {} bytes", solution.len());

    // Split header for Equihash verification
    // Header structure (140 bytes):
    // - version: 4 bytes
    // - prevHash: 32 bytes
    // - merkleRoot: 32 bytes
    // - reserved (finalSaplingRoot): 32 bytes
    // - time: 4 bytes
    // - bits: 4 bytes
    // - nonce: 32 bytes
    // Total input for Equihash: first 108 bytes (version through bits)
    // Nonce: last 32 bytes
    let input = &header[0..108];
    let nonce = &header[108..140];

    println!("\nInput (first 108 bytes of header): {:02x?}...", &input[0..16]);
    println!("Nonce (last 32 bytes): {:02x?}", nonce);

    // Test with CORRECT Zclassic parameters (192, 7) - post-Bubbles upgrade
    // Source: /Users/chris/zclassic/zclassic/src/consensus/upgrades.cpp lines 78-82
    println!("\n--- Testing Equihash(192, 7) [CORRECT for Zclassic post-Bubbles] ---");
    match equihash::is_valid_solution(192, 7, input, nonce, solution) {
        Ok(()) => println!("✅ Equihash(192, 7) verification PASSED!"),
        Err(e) => println!("❌ Equihash(192, 7) verification FAILED: {:?}", e),
    }

    // Test with OLD/WRONG parameters (200, 9) for comparison - pre-Bubbles / Zcash
    println!("\n--- Testing Equihash(200, 9) [pre-Bubbles / Zcash - should fail] ---");
    match equihash::is_valid_solution(200, 9, input, nonce, solution) {
        Ok(()) => println!("⚠️ Equihash(200, 9) verification PASSED (unexpected!)"),
        Err(e) => println!("✅ Equihash(200, 9) correctly FAILED: {:?}", e),
    }

    println!("\n=== Test Complete ===");
}
