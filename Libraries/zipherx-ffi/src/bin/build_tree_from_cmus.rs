// build_tree_from_cmus.rs
//
// Build commitment tree from CMUs and serialize with CURRENT FFI
//
// Usage:
//     cargo run --release --bin build_tree_from_cmus <cmus.bin> <output_tree.bin>
//
// Input: CMUs in legacy format [count: u64 LE][cmu1: 32][cmu2: 32]...
// Output: Serialized commitment tree (compatible with current FFI)

use std::fs;
use std::time::Instant;

/// Tree loading callback type
type TreeLoadCallback = extern "C" fn(current: u64, total: u64);

extern "C" {
    /// Load tree from CMUs (from FFI)
    fn zipherx_tree_load_from_cmus_with_progress(
        cmu_data: *const u8,
        cmu_len: usize,
        callback: TreeLoadCallback,
    ) -> bool;

    /// Serialize tree (from FFI)
    fn zipherx_tree_serialize(tree_out: *mut u8, tree_out_len: *mut usize) -> bool;

    /// Get tree size (from FFI)
    fn zipherx_tree_size() -> u64;
}

extern "C" fn progress_callback(current: u64, total: u64) {
    if total > 0 {
        let percent = (current * 100) / total;
        eprintln!("📊 Progress: {}/{} CMUs ({}%)", current, total, percent);
    }
}


fn main() {
    let args: Vec<String> = std::env::args().collect();

    if args.len() < 3 {
        eprintln!("Usage: {} <cmus.bin> <output_tree.bin>", args[0]);
        eprintln!("");
        eprintln!("Build commitment tree from CMUs and serialize with CURRENT FFI");
        eprintln!("");
        eprintln!("Input:  CMUs in legacy format [count: u64 LE][cmu1: 32][cmu2: 32]...");
        eprintln!("Output: Serialized commitment tree (compatible with current FFI)");
        std::process::exit(1);
    }

    let input_path = &args[1];
    let output_path = &args[2];

    eprintln!("🌳 Building commitment tree from CMUs...");
    eprintln!("📂 Input: {}", input_path);
    eprintln!("📂 Output: {}", output_path);

    // Read CMU data
    eprintln!("📖 Reading CMU data...");
    let start = Instant::now();
    let cmu_data = match fs::read(input_path) {
        Ok(data) => data,
        Err(e) => {
            eprintln!("❌ Failed to read CMU file: {}", e);
            std::process::exit(1);
        }
    };

    eprintln!("✅ Read {} bytes of CMU data", cmu_data.len());

    // Parse CMU count
    if cmu_data.len() < 8 {
        eprintln!("❌ CMU file too small (no count)");
        std::process::exit(1);
    }

    let cmu_count = u64::from_le_bytes([cmu_data[0], cmu_data[1], cmu_data[2], cmu_data[3],
                                       cmu_data[4], cmu_data[5], cmu_data[6], cmu_data[7]]) as usize;
    let expected_size = 8 + cmu_count * 32;

    if cmu_data.len() != expected_size {
        eprintln!("⚠️ Warning: CMU file size mismatch (expected {}, got {})", expected_size, cmu_data.len());
    }

    eprintln!("📊 CMU count: {}", cmu_count);

    // Build tree from CMUs
    eprintln!("🏗️  Building tree (this takes 30-60 seconds for 1M+ CMUs)...");
    let build_start = Instant::now();

    // FIX #518: Call library function directly (not through extern "C")
    let success = unsafe {
        zipherx_tree_load_from_cmus_with_progress(
            cmu_data.as_ptr(),
            cmu_data.len(),
            CallbackWrapper::callback,
        )
    };

    if !success {
        eprintln!("❌ Failed to build tree from CMUs");
        std::process::exit(1);
    }

    let build_duration = build_start.elapsed();
    eprintln!("✅ Tree built in {:?}", build_duration);

    // Get tree size
    // FIX #518: Call library function directly (not through extern "C")
    let tree_size = unsafe { zipherx_tree_size() };
    eprintln!("📏 Tree size: {} commitments", tree_size);

    // Serialize tree
    eprintln!("💾 Serializing tree...");

    // Allocate buffer for serialization
    let mut buffer = vec![0u8; 10_000_000]; // 10MB should be enough

    // FIX #518: Call library function directly (not through extern "C")
    let mut out_len: usize = buffer.len();

    // First call: get required size
    if unsafe { !zipherx_tree_serialize(buffer.as_mut_ptr(), &mut out_len) } {
        eprintln!("❌ Failed to serialize tree (first call)");
        std::process::exit(1);
    }

    eprintln!("✅ Serialized tree size: {} bytes", out_len);

    // Write to file
    if let Err(e) = fs::write(output_path, &buffer[..out_len]) {
        eprintln!("❌ Failed to write tree file: {}", e);
        std::process::exit(1);
    }

    let total_duration = start.elapsed();
    eprintln!("✅ Tree serialized and saved to: {}", output_path);
    eprintln!("⏱️  Total time: {:?}", total_duration);
}
