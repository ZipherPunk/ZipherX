fn main() {
    // Simple test - just check if Params::new accepts (192, 7)
    let n: u32 = 192;
    let k: u32 = 7;
    
    // Check param validity
    let valid = (n % 8 == 0) && (k >= 3) && (k < n) && (n % (k + 1) == 0);
    println!("Params (192, 7) valid: {}", valid);
    
    // Calculate solution size: (2^K) * (N/(K+1) + 1) / 8
    let solution_bits = (1 << k) * ((n / (k + 1)) + 1);
    let solution_bytes = solution_bits / 8;
    println!("Solution size for (192, 7): {} bytes (expect 400)", solution_bytes);
    
    // Test with equihash crate directly
    match equihash::is_valid_solution(n, k, &[0u8; 108], &[0u8; 32], &[0u8; 400]) {
        Ok(()) => println!("Equihash(192, 7) is accepted by crate"),
        Err(e) => println!("Equihash(192, 7) error: {:?}", e),
    }
}
