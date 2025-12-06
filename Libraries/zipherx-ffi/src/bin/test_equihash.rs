//! Test Equihash verification with real Zclassic block

fn main() {
    // Block 2926123 header + solution (first 543 bytes of raw block)
    // Header (140) + varint (3) + solution (400) = 543 bytes
    let raw_hex = "04000000cdd5281549795ad06f25cd7aa60a12993fd3e3c253945f598753286160010000011bb896d54438cedfdb15e224bbb26c206c5b9031715b698c08692ba0ad01aefca643557e3a236e3f4c1c89e6d8e3ba7e1898a356df2cb5767438c6a9ba492af9882a69e7f6041e0419163cb9aabe3b4786d3439c803950f82855020000000000000000592bd5b1fd90010014c80f0592926736bc81261143a0a791e398df81908160355ac42d35e59c1e895697e119498f3f8cdefdd7abb575e206260b9b12293a4f44538b2a08f0e18984bd10bbf63126018467fd1e0d5bb0102bb450ec7f113442bea9d9b2b93fcafc8fe64b2315f39f8f3d3187e6de67f526c61a954d20b1dedda3d1cf70ec21e8c75b34dacdc57a12e57195d23c6fd51fae4069e547222628c824b36c655b4f17360b8f1359f573875819cd96476513082c7c1f65862f1491f76ec5ff659feedc5d481ee62b1bb4f0bc02cab19c2451e4f0e798612544446402ab22225effdd45491012c2803efdc2a88b3b1cb32052578f5f74e212bee521afb4e4034cd0ba0060cfc3e77a0c95445ea91fac86e30f3657a62b240ad369614c3bac51adda52c931e8887c3212f5f605ab2ae3eb036ec2c9cc0a4672d3cf0edd95716f7cd60ffdfb880d0f99340989f724e1fc94a3a83332f9c0b222a0b32f6533510dfeded10477365d0b46da6d76101388b2270b6459cfb4e1b273fce6190b8933e6b795e2b7b45950cd21f92214b411ace14202a814f8";
    
    // Parse the hex
    let raw_bytes: Vec<u8> = (0..raw_hex.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&raw_hex[i..i+2], 16).unwrap())
        .collect();
    
    println!("Raw data length: {} bytes", raw_bytes.len());
    
    // Extract header (140 bytes)
    let header = &raw_bytes[0..140];
    
    // Parse solution length varint at offset 140
    let varint_byte = raw_bytes[140];
    let (solution_len, varint_size) = if varint_byte < 253 {
        (varint_byte as usize, 1)
    } else if varint_byte == 253 {
        let len = raw_bytes[141] as usize | ((raw_bytes[142] as usize) << 8);
        (len, 3)
    } else {
        panic!("Unsupported varint size");
    };
    
    println!("Solution length: {} bytes (expected 400 for Equihash 192,7)", solution_len);
    
    // Extract solution
    let solution_start = 140 + varint_size;
    let solution = &raw_bytes[solution_start..solution_start + solution_len];
    
    println!("Solution actual length: {} bytes", solution.len());
    
    // Split header for Equihash verification
    let input = &header[0..108];  // Version through bits
    let nonce = &header[108..140]; // 32-byte nonce
    
    // Zclassic uses Equihash(192, 7) since Bubbles upgrade at height 585,318
    // Source: /Users/chris/zclassic/zclassic/src/consensus/upgrades.cpp lines 78-82
    println!("\n--- Testing Equihash(192, 7) [CORRECT for Zclassic post-Bubbles] ---");
    match equihash::is_valid_solution(192, 7, input, nonce, solution) {
        Ok(()) => println!("✅ Equihash(192, 7) verification PASSED!"),
        Err(e) => println!("❌ Equihash(192, 7) verification FAILED: {:?}", e),
    }

    // Also test with (200, 9) for comparison - should FAIL for post-Bubbles blocks
    println!("\n--- Testing Equihash(200, 9) [pre-Bubbles / Zcash params - should fail] ---");
    match equihash::is_valid_solution(200, 9, input, nonce, solution) {
        Ok(()) => println!("⚠️ Equihash(200, 9) verification PASSED (unexpected!)"),
        Err(e) => println!("✅ Equihash(200, 9) correctly FAILED: {:?}", e),
    }
}
