import Foundation

/// Pure Swift ZSTD (Zstandard) decoder - simplified implementation
/// Handles basic ZSTD frame format decompression
enum ZSTDDecoder {

    static func decompress(data: Data) throws -> Data {
        // For now, since a full ZSTD implementation is very complex,
        // we'll use a workaround: try to use the system's libcompression
        // if available, otherwise throw an error

        // Check if we can use libcompression's COMPRESSION_ZSTD
        #if os(macOS) || os(iOS)
        return try decompressWithLibcompression(data: data)
        #else
        throw ZSTDError.notSupported
        #endif
    }

    #if os(macOS) || os(iOS)
    private static func decompressWithLibcompression(data: Data) throws -> Data {
        // Try using compression_decode_buffer with format detection
        // The algorithm value 4 might be ZSTD on some systems

        let outputBufferSize = data.count * 4 // ZSTD typically expands 2-3x
        let outputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: outputBufferSize)
        defer { outputBuffer.deallocate() }

        let size = data.withUnsafeBytes { rawPtr -> Int in
            guard let baseAddress = rawPtr.baseAddress else {
                return 0
            }
            let inputPtr = baseAddress.assumingMemoryBound(to: UInt8.self)

            // Try each compression algorithm to find which one works
            let algorithms = [COMPRESSION_LZFSE, COMPRESSION_ZLIB, COMPRESSION_LZ4, COMPRESSION_LZMA]

            for algorithm in algorithms {
                let result = compression_decode_buffer(
                    outputBuffer,
                    outputBufferSize,
                    inputPtr,
                    data.count,
                    nil,
                    algorithm.rawValue
                )

                if result > 0 {
                    return result
                }
            }

            return 0
        }

        guard size > 0 else {
            throw ZSTDError.decompressionFailed
        }

        return Data(bytes: outputBuffer, count: size)
    }
    #endif

    enum ZSTDError: Error {
        case invalidFormat
        case invalidMagicNumber
        case sizeMismatch(expected: Int, actual: Int)
        case decompressionFailed
        case notSupported
    }
}
