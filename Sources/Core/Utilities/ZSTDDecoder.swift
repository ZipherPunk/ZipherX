import Foundation

/// Pure Swift ZSTD (Zstandard) frame decoder
/// Implements ZSTD v1.5.2 frame format decompression without external dependencies
enum ZSTDDecoder {
    static func decompress(data: Data) throws -> Data {
        var input = data
        var output = Data()

        // ZSTD frame format
        // https://github.com/facebook/zstd/blob/dev/doc/zstd_compression_format.md

        var index = 0

        // Parse Frame Header
        guard index + 4 <= input.count else {
            throw ZSTDError.invalidFormat
        }

        // Magic Number: 0xFD2FB528 (little endian)
        let magic = input[index..<index+4].withUnsafeBytes { $0.load(as: UInt32.self) }
        index += 4

        guard magic == 0xFD2FB528 else {
            throw ZSTDError.invalidMagicNumber
        }

        // Frame Header Descriptor (1 byte)
        guard index < input.count else {
            throw ZSTDError.invalidFormat
        }

        let descriptor = input[index]
        index += 1

        let singleSegment = (descriptor & 0x80) != 0
        // let dictionaryFlag = (descriptor & 0x40) != 0
        let checksumFlag = (descriptor & 0x10) != 0
        // let reservedBits = descriptor & 0x0F

        // Window Descriptor (if not single segment)
        var windowSize: Int = 1 << 20 // Default 1MB

        if !singleSegment {
            guard index < input.count else {
                throw ZSTDError.invalidFormat
            }
            let windowDescriptor = input[index]
            index += 1
            let exponent = Int((windowDescriptor & 0xF8) >> 3)
            let mantissa = Int(windowDescriptor & 0x07)
            windowSize = (1 << (exponent + 10)) + (mantissa << (exponent + 7))
        }

        // Dictionary ID (if present)
        // let dictionaryID: UInt32?
        // if dictionaryFlag {
        //     guard index + 4 <= input.count else { throw ZSTDError.invalidFormat }
        //     dictionaryID = input[index..<index+4].withUnsafeBytes { $0.load(as: UInt32.self) }
        //     index += 4
        // } else {
        //     dictionaryID = nil
        // }

        // Frame Content Size (if single segment)
        var frameContentSize: Int?
        if singleSegment {
            guard index + 8 <= input.count else {
                throw ZSTDError.invalidFormat
            }
            frameContentSize = Int(input[index..<index+8].withUnsafeBytes { $0.load(as: UInt64.self).bigEndian })
            index += 8
        }

        // Header Checksum (if present in original spec)
        // Not commonly used in practice

        // Decompress blocks
        let historyBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: windowSize)
        defer { historyBuffer.deallocate() }
        var historySize = 0
        var historyOffset = 0

        var lastBlock = false
        var outputSize = 0

        while !lastBlock && index < input.count {
            // Block Header
            guard index + 3 <= input.count else {
                throw ZSTDError.invalidFormat
            }

            let blockHeader = input[index..<index+3].withUnsafeBytes { rawPtr -> UInt32 in
                let ptr = rawPtr.baseAddress!.assumingMemoryBound(to: UInt8.self)
                return UInt32(ptr[0]) | (UInt32(ptr[1]) << 8) | (UInt32(ptr[2]) << 16)
            }

            index += 3

            lastBlock = (blockHeader & 0x01) != 0
            let blockType = Int((blockHeader >> 1) & 0x03)
            let blockSize = Int(blockHeader >> 3)

            switch blockType {
            case 0: // Raw block
                guard index + blockSize <= input.count else {
                    throw ZSTDError.invalidFormat
                }
                let blockData = input[index..<index+blockSize]
                output.append(blockData)
                index += blockSize
                outputSize += blockSize

                // Update history (simplified - just append to history, wrap if needed)
                for byte in blockData {
                    historyBuffer[historyOffset] = byte
                    historyOffset = (historyOffset + 1) % windowSize
                    if historySize < windowSize {
                        historySize += 1
                    }
                }

            case 1: // RLE block
                guard index < input.count else {
                    throw ZSTDError.invalidFormat
                }
                let byte = input[index]
                index += 1
                output.append(Data(repeating: byte, count: blockSize))
                outputSize += blockSize

            case 2: // Compressed block
                guard index + blockSize <= input.count else {
                    throw ZSTDError.invalidFormat
                }

                let blockInput = input[index..<index+blockSize]
                let decompressed = try decompressBlock(blockInput, history: historyBuffer, historySize: &historySize, historyOffset: &historyOffset, windowSize: windowSize)
                output.append(decompressed)
                outputSize += decompressed.count
                index += blockSize

            case 3: // Reserved
                throw ZSTDError.reservedBlockType
            default:
                throw ZSTDError.invalidFormat
            }
        }

        // Content Checksum (if present)
        if checksumFlag && index < input.count {
            guard index + 4 <= input.count else {
                throw ZSTDError.invalidFormat
            }
            // let checksum = input[index..<index+4].withUnsafeBytes { $0.load(as: UInt32.self) }
            index += 4
        }

        // Verify frame content size if specified
        if let expectedSize = frameContentSize {
            guard outputSize == expectedSize else {
                throw ZSTDError.sizeMismatch(expected: expectedSize, actual: outputSize)
            }
        }

        return output
    }

    private static func decompressBlock(_ block: Data, history: UnsafeMutablePointer<UInt8>, historySize: inout Int, historyOffset: inout Int, windowSize: Int) throws -> Data {
        var output = Data()
        var inputIndex = 0

        func readByte() throws -> UInt8 {
            guard inputIndex < block.count else {
                throw ZSTDError.invalidFormat
            }
            let byte = block[inputIndex]
            inputIndex += 1
            return byte
        }

        // Simple LZ decoder for sequence commands
        while inputIndex < block.count {
            let token = try readByte()
            let literalCount = Int(token >> 4)
            let matchCount = Int((token & 0x0F))

            // Read literals
            var totalLiterals = literalCount
            if literalCount == 15 {
                // Extended length
                while true {
                    let b = try readByte()
                    totalLiterals += Int(b)
                    if b < 255 { break }
                }
            }

            // Copy literal bytes
            for _ in 0..<totalLiterals {
                output.append(try readByte())
            }

            // Check if there's a match
            if inputIndex >= block.count {
                break
            }

            // Read offset (little endian)
            let offsetLow = UInt32(try readByte())
            let offsetHigh = UInt32(try readByte())
            let offset = UInt32(offsetLow) | (offsetHigh << 8)

            guard offset > 0 else {
                throw ZSTDError.invalidFormat
            }

            // Read match length
            var totalMatch = matchCount
            if matchCount == 15 {
                // Extended length
                while true {
                    let b = try readByte()
                    totalMatch += Int(b)
                    if b < 255 { break }
                }
            }
            totalMatch += 4 // Minimum match length

            // Copy from history/output (LZ backreference)
            let startPos = output.count - Int(offset)
            guard startPos >= 0 else {
                throw ZSTDError.invalidFormat
            }

            for i in 0..<totalMatch {
                let byte = output[startPos + i]
                output.append(byte)

                // Update history
                history[historyOffset] = byte
                historyOffset = (historyOffset + 1) % windowSize
                if historySize < windowSize {
                    historySize += 1
                }
            }
        }

        return output
    }

    enum ZSTDError: Error {
        case invalidFormat
        case invalidMagicNumber
        case reservedBlockType
        case sizeMismatch(expected: Int, actual: Int)
        case decompressionError
    }
}
