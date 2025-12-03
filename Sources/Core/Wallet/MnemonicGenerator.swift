import Foundation
import CryptoKit

/// BIP-39 Mnemonic Generator
/// Generates and validates mnemonic seed phrases for wallet backup
final class MnemonicGenerator {

    // MARK: - BIP-39 English Wordlist (2048 words)
    // This is a subset - full list would be loaded from resource file
    private static let wordlist: [String] = {
        // In production, load from BIP39 wordlist file
        // For now, using placeholder that would be replaced
        return BIP39Wordlist.english
    }()

    // MARK: - Mnemonic Generation

    /// Generate a new mnemonic phrase
    /// - Parameter wordCount: Number of words (12, 15, 18, 21, or 24)
    /// - Returns: Array of mnemonic words
    func generateMnemonic(wordCount: Int = 24) throws -> [String] {
        // Calculate entropy bytes needed
        // 12 words = 128 bits, 24 words = 256 bits
        let entropyBits: Int
        switch wordCount {
        case 12: entropyBits = 128
        case 15: entropyBits = 160
        case 18: entropyBits = 192
        case 21: entropyBits = 224
        case 24: entropyBits = 256
        default:
            throw MnemonicError.invalidWordCount
        }

        let entropyBytes = entropyBits / 8

        // Generate cryptographically secure random entropy
        var entropy = Data(count: entropyBytes)
        let result = entropy.withUnsafeMutableBytes { ptr in
            SecRandomCopyBytes(kSecRandomDefault, entropyBytes, ptr.baseAddress!)
        }

        guard result == errSecSuccess else {
            throw MnemonicError.randomGenerationFailed
        }

        return try entropyToMnemonic(entropy)
    }

    /// Convert entropy to mnemonic words
    private func entropyToMnemonic(_ entropy: Data) throws -> [String] {
        // Calculate checksum
        let hash = SHA256.hash(data: entropy)
        let hashData = Data(hash)

        // Append checksum bits to entropy
        var bits = entropy.toBitArray()
        let checksumBits = entropy.count / 4 // 1 bit per 32 bits of entropy
        let hashBits = hashData.toBitArray()
        bits.append(contentsOf: hashBits.prefix(checksumBits))

        // Split into 11-bit groups and map to words
        var words: [String] = []
        for i in stride(from: 0, to: bits.count, by: 11) {
            let end = min(i + 11, bits.count)
            let wordBits = Array(bits[i..<end])
            let index = wordBits.toInt()

            guard index < Self.wordlist.count else {
                throw MnemonicError.invalidIndex
            }

            words.append(Self.wordlist[index])
        }

        return words
    }

    // MARK: - Mnemonic Validation

    /// Validate a mnemonic phrase
    func validateMnemonic(_ words: [String]) -> Bool {
        Swift.print("🔍 VALIDATE [1]: Starting validation for \(words.count) words")

        // Check word count
        guard [12, 15, 18, 21, 24].contains(words.count) else {
            Swift.print("❌ VALIDATE: Invalid word count")
            return false
        }
        Swift.print("🔍 VALIDATE [2]: Word count OK")

        // Check all words are in wordlist
        Swift.print("🔍 VALIDATE [3]: Checking words against wordlist (size: \(Self.wordlist.count))...")
        for (idx, word) in words.enumerated() {
            let lowered = word.lowercased()
            if !Self.wordlist.contains(lowered) {
                Swift.print("❌ VALIDATE: Word '\(word)' not in wordlist at index \(idx)")
                return false
            }
        }
        Swift.print("🔍 VALIDATE [4]: All words found in wordlist")

        // Verify checksum
        Swift.print("🔍 VALIDATE [5]: Converting to entropy...")
        guard let entropy = try? mnemonicToEntropy(words) else {
            Swift.print("❌ VALIDATE: mnemonicToEntropy failed")
            return false
        }
        Swift.print("🔍 VALIDATE [6]: Entropy obtained (\(entropy.count) bytes)")

        // Recalculate checksum
        Swift.print("🔍 VALIDATE [7]: Computing checksum...")
        let hash = SHA256.hash(data: entropy)
        let hashData = Data(hash)
        let expectedChecksum = hashData.toBitArray().prefix(words.count / 3)
        Swift.print("🔍 VALIDATE [8]: Expected checksum computed")

        // Get actual checksum from mnemonic
        var bits: [Bool] = []
        for word in words {
            guard let index = Self.wordlist.firstIndex(of: word.lowercased()) else {
                return false
            }
            bits.append(contentsOf: index.toBitArray(width: 11))
        }

        let entropyBitCount = (words.count * 11) - (words.count / 3)
        Swift.print("🔍 VALIDATE [9]: bits.count=\(bits.count), entropyBitCount=\(entropyBitCount)")

        let actualChecksum = bits.suffix(from: entropyBitCount)
        Swift.print("🔍 VALIDATE [10]: Comparing checksums...")

        let result = Array(expectedChecksum) == Array(actualChecksum)
        Swift.print("🔍 VALIDATE [11]: Result = \(result)")
        return result
    }

    /// Convert mnemonic back to entropy
    private func mnemonicToEntropy(_ words: [String]) throws -> Data {
        var bits: [Bool] = []

        for word in words {
            guard let index = Self.wordlist.firstIndex(of: word.lowercased()) else {
                throw MnemonicError.invalidWord(word)
            }
            bits.append(contentsOf: index.toBitArray(width: 11))
        }

        // Remove checksum bits
        let checksumBits = words.count / 3

        // Safety check: ensure we have enough bits
        guard bits.count > checksumBits else {
            throw MnemonicError.invalidWordCount
        }

        let entropyBits = Array(bits.dropLast(checksumBits))

        // Safety check: entropy bits should be divisible by 8
        guard entropyBits.count % 8 == 0 && entropyBits.count > 0 else {
            throw MnemonicError.invalidWordCount
        }

        let bytes = entropyBits.toBytes()
        return Data(bytes)
    }

    // MARK: - Seed Derivation

    /// Derive seed from mnemonic using PBKDF2
    /// - Parameters:
    ///   - mnemonic: Array of mnemonic words
    ///   - passphrase: Optional passphrase (empty string if none)
    /// - Returns: 64-byte seed
    func mnemonicToSeed(mnemonic: [String], passphrase: String = "") throws -> Data {
        let mnemonicString = mnemonic.joined(separator: " ")
        let salt = "mnemonic" + passphrase

        guard let passwordData = mnemonicString.data(using: .utf8),
              let saltData = salt.data(using: .utf8) else {
            throw MnemonicError.encodingFailed
        }

        // PBKDF2-SHA512 with 2048 iterations
        var derivedKey = Data(count: 64)
        let result = derivedKey.withUnsafeMutableBytes { derivedKeyPtr in
            saltData.withUnsafeBytes { saltPtr in
                passwordData.withUnsafeBytes { passwordPtr in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordPtr.baseAddress?.assumingMemoryBound(to: Int8.self),
                        passwordData.count,
                        saltPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        saltData.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512),
                        2048,
                        derivedKeyPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        64
                    )
                }
            }
        }

        guard result == kCCSuccess else {
            throw MnemonicError.pbkdfFailed
        }

        return derivedKey
    }
}

// MARK: - Mnemonic Errors
enum MnemonicError: LocalizedError {
    case invalidWordCount
    case randomGenerationFailed
    case invalidIndex
    case invalidWord(String)
    case encodingFailed
    case pbkdfFailed

    var errorDescription: String? {
        switch self {
        case .invalidWordCount:
            return "Invalid word count. Must be 12, 15, 18, 21, or 24"
        case .randomGenerationFailed:
            return "Failed to generate random entropy"
        case .invalidIndex:
            return "Invalid word index"
        case .invalidWord(let word):
            return "Invalid word: \(word)"
        case .encodingFailed:
            return "Failed to encode mnemonic"
        case .pbkdfFailed:
            return "Failed to derive seed"
        }
    }
}

// MARK: - Helper Extensions
private extension Data {
    func toBitArray() -> [Bool] {
        var bits: [Bool] = []
        for byte in self {
            for i in (0..<8).reversed() {
                bits.append((byte >> i) & 1 == 1)
            }
        }
        return bits
    }
}

private extension Array where Element == Bool {
    func toInt() -> Int {
        var result = 0
        for bit in self {
            result = (result << 1) | (bit ? 1 : 0)
        }
        return result
    }

    func toBytes() -> [UInt8] {
        var bytes: [UInt8] = []
        var byte: UInt8 = 0
        var bitCount = 0

        for bit in self {
            byte = (byte << 1) | (bit ? 1 : 0)
            bitCount += 1
            if bitCount == 8 {
                bytes.append(byte)
                byte = 0
                bitCount = 0
            }
        }

        return bytes
    }
}

private extension Int {
    func toBitArray(width: Int) -> [Bool] {
        var bits: [Bool] = []
        for i in (0..<width).reversed() {
            bits.append((self >> i) & 1 == 1)
        }
        return bits
    }
}

// MARK: - CommonCrypto Bridge
import CommonCrypto
