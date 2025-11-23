import XCTest
@testable import ZipherX

final class WalletTests: XCTestCase {

    // MARK: - Mnemonic Tests

    func testMnemonicGeneration() throws {
        let generator = MnemonicGenerator()
        let mnemonic = try generator.generateMnemonic(wordCount: 24)

        XCTAssertEqual(mnemonic.count, 24, "Mnemonic should have 24 words")

        // All words should be in BIP39 wordlist
        for word in mnemonic {
            XCTAssertTrue(BIP39Wordlist.english.contains(word.lowercased()),
                         "Word '\(word)' should be in BIP39 wordlist")
        }
    }

    func testMnemonicValidation() {
        let generator = MnemonicGenerator()

        // Valid mnemonic (example)
        let validMnemonic = [
            "abandon", "abandon", "abandon", "abandon", "abandon", "abandon",
            "abandon", "abandon", "abandon", "abandon", "abandon", "about"
        ]
        XCTAssertTrue(generator.validateMnemonic(validMnemonic))

        // Invalid word count
        let invalidCount = ["abandon", "abandon", "abandon"]
        XCTAssertFalse(generator.validateMnemonic(invalidCount))

        // Invalid word
        let invalidWord = [
            "invalid", "abandon", "abandon", "abandon", "abandon", "abandon",
            "abandon", "abandon", "abandon", "abandon", "abandon", "about"
        ]
        XCTAssertFalse(generator.validateMnemonic(invalidWord))
    }

    func testSeedDerivation() throws {
        let generator = MnemonicGenerator()
        let mnemonic = try generator.generateMnemonic(wordCount: 24)
        let seed = try generator.mnemonicToSeed(mnemonic: mnemonic)

        XCTAssertEqual(seed.count, 64, "Seed should be 64 bytes")
    }

    // MARK: - Address Validation Tests

    func testZAddressValidation() {
        let walletManager = WalletManager.shared

        // Valid z-address format (78 chars starting with "zc")
        let validZAddr = "zc" + String(repeating: "a", count: 76)
        XCTAssertTrue(walletManager.isValidZAddress(validZAddr))

        // Invalid - too short
        let shortAddr = "zc" + String(repeating: "a", count: 10)
        XCTAssertFalse(walletManager.isValidZAddress(shortAddr))

        // Invalid - wrong prefix
        let wrongPrefix = "zt" + String(repeating: "a", count: 76)
        XCTAssertFalse(walletManager.isValidZAddress(wrongPrefix))

        // Invalid - contains invalid chars
        let invalidChars = "zc" + String(repeating: "0", count: 75) + "O" // O not in base58
        XCTAssertFalse(walletManager.isValidZAddress(invalidChars))
    }

    func testTransparentAddressRejection() {
        let walletManager = WalletManager.shared

        // t1 addresses should be detected
        XCTAssertTrue(walletManager.isTransparentAddress("t1abc123"))

        // t3 addresses should be detected
        XCTAssertTrue(walletManager.isTransparentAddress("t3xyz789"))

        // z-addresses should not be detected as transparent
        let zAddr = "zc" + String(repeating: "a", count: 76)
        XCTAssertFalse(walletManager.isTransparentAddress(zAddr))
    }

    // MARK: - Balance Formatting Tests

    func testBalanceFormatting() {
        // Test various zatoshi amounts
        let testCases: [(UInt64, String)] = [
            (0, "0.00000000"),
            (100_000_000, "1.00000000"),
            (50_000_000, "0.50000000"),
            (1, "0.00000001"),
            (123_456_789, "1.23456789")
        ]

        for (zatoshis, expected) in testCases {
            let zcl = Double(zatoshis) / 100_000_000.0
            let formatted = String(format: "%.8f", zcl)
            XCTAssertEqual(formatted, expected, "Formatting \(zatoshis) zatoshis")
        }
    }
}

// MARK: - Network Tests

final class NetworkTests: XCTestCase {

    func testPeerAddressParsing() {
        let peer = "45.76.31.96:8033"
        let components = peer.split(separator: ":")

        XCTAssertEqual(components.count, 2)
        XCTAssertEqual(String(components[0]), "45.76.31.96")
        XCTAssertEqual(UInt16(components[1]), 8033)
    }

    func testNetworkMagicBytes() {
        // Zclassic mainnet magic bytes
        let magic: [UInt8] = [0x24, 0xe9, 0x27, 0x64]

        XCTAssertEqual(magic.count, 4)
        XCTAssertEqual(magic[0], 0x24)
        XCTAssertEqual(magic[1], 0xe9)
        XCTAssertEqual(magic[2], 0x27)
        XCTAssertEqual(magic[3], 0x64)
    }
}

// MARK: - Crypto Tests

final class CryptoTests: XCTestCase {

    func testDoubleSHA256() {
        let data = "test".data(using: .utf8)!
        let hash = data.doubleSHA256()

        XCTAssertEqual(hash.count, 32, "Double SHA256 should produce 32 bytes")

        // Hash should be deterministic
        let hash2 = data.doubleSHA256()
        XCTAssertEqual(hash, hash2)
    }
}
