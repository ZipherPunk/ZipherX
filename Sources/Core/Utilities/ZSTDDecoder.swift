import Foundation

/// ZSTD decompression using bundled libzstd (via Rust FFI)
/// Self-contained, no external dependencies
enum ZSTDDecoder {

    /// Decompress ZSTD data using the Rust FFI zstd crate
    static func decompress(data: Data) throws -> Data {
        var outPtr: UnsafeMutablePointer<UInt8>?
        var outLen: Int = 0

        let result = data.withUnsafeBytes { rawPtr -> UInt32 in
            guard let baseAddress = rawPtr.baseAddress else {
                return 0
            }
            return zipherx_zstd_decompress(
                baseAddress.assumingMemoryBound(to: UInt8.self),
                data.count,
                &outPtr,
                &outLen
            )
        }

        guard result == 1, let ptr = outPtr else {
            throw ZSTDError.decompressionFailed("ZSTD decompression returned error")
        }

        guard outLen > 0 else {
            throw ZSTDError.decompressionFailed("ZSTD decompression returned empty data")
        }

        // Copy data to Swift Data and free the Rust buffer
        let decompressed = Data(bytes: ptr, count: outLen)
        zipherx_free_buffer(ptr)

        return decompressed
    }

    enum ZSTDError: Error {
        case decompressionFailed(String)
    }
}
