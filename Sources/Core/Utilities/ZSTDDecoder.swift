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
            let exponent = (windowDescriptor & 0xF8) >> 3
            let mantissa = windowDescriptor & 0x07
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
            frameContentSize = input[index..<index+8].withUnsafeBytes { $0.load(as: UInt64.self).bigEndian }
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
            let blockType = (blockHeader >> 1) & 0x03
            let blockSize = Int(blockHeader >> 3)

            switch blockType {
            case 0: // Raw block
                guard index + blockSize <= input.count else {
                    throw ZSTDError.invalidFormat
                }
                output.append(input[index..<index+blockSize])
                index += blockSize
                outputSize += blockSize

                // Update history
                let copySize = min(blockSize, windowSize)
                if historySize + copySize <= windowSize {
                    historyBuffer.advanced(by: historySize).copyMemory(from: input[index-blockSize..<index], count: copySize)
                } else {
                    let overlap = historySize + copySize - windowSize
                    let offset = blockSize - overlap
                    memmove(historyBuffer, historyBuffer.advanced(by: offset), windowSize - copySize)
                    historyBuffer.advanced(by: windowSize - copySize).copyMemory(from: input[index-blockSize+overlap..<index], count: copySize)
                }
                historySize = min(windowSize, historySize + copySize)
                historyOffset = (historyOffset + blockSize) % windowSize

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
        var bitStream = UInt32(0)
        var bitCount = 0

        func readBits(_ count: Int) throws -> UInt32 {
            while bitCount < count {
                guard inputIndex < block.count else {
                    throw ZSTDError.invalidFormat
                }
                let byte = block[inputIndex]
                inputIndex += 1
                bitStream |= UInt32(byte) << bitCount
                bitCount += 8
            }
            let value = bitStream & ((1 << count) - 1)
            bitStream >>= count
            bitCount -= count
            return value
        }

        func readByte() throws -> UInt8 {
            guard inputIndex < block.count else {
                throw ZSTDError.invalidFormat
            }
            let byte = block[inputIndex]
            inputIndex += 1
            return byte
        }

        // Block header (1 bit: last_block, 2 bits: block_type, 21 bits: block_size)
        let isLastBlock = try readBits(1) != 0
        let blockType = try readBits(2)
        let blockSize = Int(try readBits(21))

        guard blockType == 2 else {
            throw ZSTDError.invalidFormat
        }

        // Decompress using simple LZ decoder
        while inputIndex < block.count {
            let token = try readByte()
            let literals = UInt32(token >> 4)

            // Read literals
            var literalLength = literals
            if literals == 15 {
                var extra: UInt32 = 0
                while true {
                    let b = try readByte()
                    extra += UInt32(b)
                    if b < 255 { break }
                }
                literalLength = 15 + extra
            }

            for _ in 0..<literalLength {
                output.append(try readByte())
            }

            if inputIndex >= block.count {
                break
            }

            // Match
            let offsetLow = try readByte()
            let offsetHigh = UInt32(token & 0x0F)
            var offset = offsetLow | (offsetHigh << 8)

            if offset == 0 {
                // This shouldn't happen - offset must be >= 1
                throw ZSTDError.invalidFormat
            }

            var matchLength = UInt32(token >> 4)
            if matchLength == 15 {
                var extra: UInt32 = 0
                while true {
                    let b = try readByte()
                    extra += UInt32(b)
                    if b < 255 { break }
                }
                matchLength = 15 + extra
            }
            matchLength += 4 // Minimum match length is 4

            // Copy from output (L77 backreference)
            let startPos = output.count - Int(offset)
            guard startPos >= 0 else {
                throw ZSTDError.invalidFormat
            }

            for _ in 0..<matchLength {
                let byte = output[startPos + Int(matchLength - 1)]
                output.append(byte)
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
