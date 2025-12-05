import Foundation

/// Swift wrapper for ZipherX Rust FFI functions
enum ZipherXFFI {

    // MARK: - Library Info & Verification

    /// Get library version (3 = with ZclassicButtercup support)
    static func version() -> UInt32 {
        return zipherx_version()
    }

    /// Get the consensus branch ID for a given block height
    /// Returns 0x930b540d for heights >= 707,000 (ZclassicButtercup)
    static func getBranchId(height: UInt64) -> UInt32 {
        return zipherx_get_branch_id(height)
    }

    /// Verify the library supports ZclassicButtercup branch ID
    /// Returns true if the library is built with the correct local fork
    static func verifyButtercupSupport() -> Bool {
        return zipherx_verify_buttercup_support()
    }

    /// Debug: Print branch ID info for current chain height
    static func debugBranchId(chainHeight: UInt64) {
        let branchId = getBranchId(height: chainHeight)
        let version = version()

        print("🔐 ZipherXFFI Branch ID Debug:")
        print("   Library version: \(version)")
        print("   Chain height: \(chainHeight)")
        print("   Branch ID: 0x\(String(format: "%08x", branchId))")

        if branchId == 0x930b540d {
            print("   ✅ CORRECT: Using ZclassicButtercup (0x930b540d)")
        } else if chainHeight >= 707000 {
            print("   ❌ ERROR: Expected 0x930b540d but got 0x\(String(format: "%08x", branchId))")
        } else {
            print("   ℹ️ Using pre-Buttercup branch ID (height < 707000)")
        }
    }

    // MARK: - Mnemonic Functions

    /// Generate a new 24-word BIP-39 mnemonic
    static func generateMnemonic() -> String? {
        var buffer = [UInt8](repeating: 0, count: 256)
        let length = zipherx_generate_mnemonic(&buffer)

        guard length > 0 else {
            return nil
        }

        return String(bytes: buffer.prefix(length), encoding: .utf8)
    }

    /// Validate a BIP-39 mnemonic phrase
    static func validateMnemonic(_ phrase: String) -> Bool {
        return phrase.withCString { ptr in
            zipherx_validate_mnemonic(ptr)
        }
    }

    /// Derive 64-byte seed from mnemonic
    static func mnemonicToSeed(_ phrase: String) -> Data? {
        var seed = [UInt8](repeating: 0, count: 64)

        let success = phrase.withCString { ptr in
            zipherx_mnemonic_to_seed(ptr, &seed)
        }

        guard success else {
            return nil
        }

        return Data(seed)
    }

    // MARK: - Key Derivation

    /// Derive spending key from seed (169 bytes: serialized ExtendedSpendingKey)
    static func deriveSpendingKey(from seed: Data, account: UInt32 = 0) -> Data? {
        guard seed.count == 64 else {
            return nil
        }

        var spendingKey = [UInt8](repeating: 0, count: 169)

        let success = seed.withUnsafeBytes { seedPtr in
            zipherx_derive_spending_key(
                seedPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                account,
                &spendingKey
            )
        }

        guard success else {
            return nil
        }

        return Data(spendingKey)
    }

    /// Derive payment address from spending key (169 bytes)
    static func deriveAddress(from spendingKey: Data, diversifierIndex: UInt64 = 0) -> Data? {
        guard spendingKey.count == 169 else {
            return nil
        }

        var address = [UInt8](repeating: 0, count: 43)

        let success = spendingKey.withUnsafeBytes { skPtr in
            zipherx_derive_address(
                skPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                diversifierIndex,
                &address
            )
        }

        guard success else {
            return nil
        }

        return Data(address)
    }

    /// Derive incoming viewing key from spending key (169 bytes)
    static func deriveIVK(from spendingKey: Data) -> Data? {
        guard spendingKey.count == 169 else {
            return nil
        }

        var ivk = [UInt8](repeating: 0, count: 32)

        let success = spendingKey.withUnsafeBytes { skPtr in
            zipherx_derive_ivk(
                skPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                &ivk
            )
        }

        guard success else {
            return nil
        }

        return Data(ivk)
    }

    /// Compute nullifier for a note using proper Sapling cryptography
    /// Requires the spending key (169 bytes) to derive nk for PRF_nf
    static func computeNullifier(
        spendingKey: Data,  // Changed: now takes spending key (169 bytes) not viewing key
        diversifier: Data,
        value: UInt64,
        rcm: Data,
        position: UInt64
    ) -> Data? {
        guard spendingKey.count == 169,
              diversifier.count == 11,
              rcm.count == 32 else {
            print("⚠️ computeNullifier: invalid input sizes - sk=\(spendingKey.count), div=\(diversifier.count), rcm=\(rcm.count)")
            return nil
        }

        var nullifier = [UInt8](repeating: 0, count: 32)

        let success = spendingKey.withUnsafeBytes { skPtr in
            diversifier.withUnsafeBytes { divPtr in
                rcm.withUnsafeBytes { rcmPtr in
                    zipherx_compute_nullifier(
                        skPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        divPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        value,
                        rcmPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        position,
                        &nullifier
                    )
                }
            }
        }

        guard success else {
            print("⚠️ computeNullifier: FFI returned false")
            return nil
        }

        return Data(nullifier)
    }

    // MARK: - Address Functions

    /// Encode address bytes as z-address string
    static func encodeAddress(_ addressBytes: Data) -> String? {
        guard addressBytes.count == 43 else {
            return nil
        }

        var buffer = [UInt8](repeating: 0, count: 128)

        let length = addressBytes.withUnsafeBytes { ptr in
            zipherx_encode_address(
                ptr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                &buffer
            )
        }

        guard length > 0 else {
            return nil
        }

        return String(bytes: buffer.prefix(length), encoding: .utf8)
    }

    /// Decode z-address string to bytes
    static func decodeAddress(_ address: String) -> Data? {
        var bytes = [UInt8](repeating: 0, count: 43)

        let success = address.withCString { ptr in
            zipherx_decode_address(ptr, &bytes)
        }

        guard success else {
            return nil
        }

        return Data(bytes)
    }

    /// Validate a z-address
    static func validateAddress(_ address: String) -> Bool {
        return address.withCString { ptr in
            zipherx_validate_address(ptr)
        }
    }

    // MARK: - Note Decryption

    /// Try to decrypt a Sapling note with incoming viewing key
    /// Returns decrypted note data (diversifier + value + rcm + memo) or nil if not for us
    static func tryDecryptNote(
        ivk: Data,
        epk: Data,
        cmu: Data,
        ciphertext: Data
    ) -> Data? {
        guard ivk.count == 32,
              epk.count == 32,
              cmu.count == 32,
              ciphertext.count >= 580 else {
            return nil
        }

        var output = [UInt8](repeating: 0, count: 564)

        let length = ivk.withUnsafeBytes { ivkPtr in
            epk.withUnsafeBytes { epkPtr in
                cmu.withUnsafeBytes { cmuPtr in
                    ciphertext.withUnsafeBytes { ciphertextPtr in
                        zipherx_try_decrypt_note(
                            ivkPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                            epkPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                            cmuPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                            ciphertextPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                            &output
                        )
                    }
                }
            }
        }

        guard length > 0 else {
            return nil
        }

        return Data(output.prefix(length))
    }

    /// Try to decrypt a Sapling note using the spending key (includes IVK derivation)
    static func tryDecryptNoteWithSK(
        spendingKey: Data,
        epk: Data,
        cmu: Data,
        ciphertext: Data
    ) -> Data? {
        guard spendingKey.count == 169,
              epk.count == 32,
              cmu.count == 32,
              ciphertext.count >= 580 else {
            return nil
        }

        var output = [UInt8](repeating: 0, count: 564)

        let length = spendingKey.withUnsafeBytes { skPtr in
            epk.withUnsafeBytes { epkPtr in
                cmu.withUnsafeBytes { cmuPtr in
                    ciphertext.withUnsafeBytes { ciphertextPtr in
                        zipherx_try_decrypt_note_with_sk(
                            skPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                            epkPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                            cmuPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                            ciphertextPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                            &output
                        )
                    }
                }
            }
        }

        guard length > 0 else {
            return nil
        }

        return Data(output.prefix(length))
    }

    // MARK: - Parallel Note Decryption (6.7x speedup)

    /// Structure to hold a shielded output for batch decryption
    /// Named with FFI prefix to avoid conflict with InsightAPI.ShieldedOutput
    struct FFIShieldedOutput {
        let epk: Data      // 32 bytes (wire format / little-endian)
        let cmu: Data      // 32 bytes (wire format / little-endian)
        let ciphertext: Data // 580 bytes

        /// Create from InsightAPI hex strings (handles byte order conversion)
        init(epkHex: String, cmuHex: String, ciphertextHex: String) {
            // InsightAPI returns big-endian (display format) - reverse to wire format
            let epkDisplay = Data(hexString: epkHex) ?? Data(count: 32)
            let cmuDisplay = Data(hexString: cmuHex) ?? Data(count: 32)
            let enc = Data(hexString: ciphertextHex) ?? Data(count: 580)

            self.epk = epkDisplay.reversedBytes()
            self.cmu = cmuDisplay.reversedBytes()
            self.ciphertext = enc.count >= 580 ? Data(enc.prefix(580)) : enc
        }

        /// Create from raw bytes (already in wire format)
        init(epk: Data, cmu: Data, ciphertext: Data) {
            self.epk = epk
            self.cmu = cmu
            self.ciphertext = ciphertext
        }
    }

    /// Result of parallel decryption for a single output
    struct FFIDecryptedNote {
        let diversifier: Data  // 11 bytes
        let value: UInt64
        let rcm: Data         // 32 bytes
        let memo: Data        // 512 bytes
    }

    /// Get the number of CPU threads used by Rayon for parallel decryption
    static func getRayonThreads() -> Int {
        return Int(zipherx_get_rayon_threads())
    }

    /// Batch decrypt multiple shielded outputs in parallel using Rayon
    /// This provides ~6.7x speedup over sequential decryption by using all CPU cores
    ///
    /// - Parameters:
    ///   - spendingKey: 169-byte spending key
    ///   - outputs: Array of shielded outputs to decrypt
    ///   - height: Block height for version byte validation
    /// - Returns: Array of optional FFIDecryptedNote (nil for outputs not belonging to us)
    static func tryDecryptNotesParallel(
        spendingKey: Data,
        outputs: [FFIShieldedOutput],
        height: UInt64
    ) -> [FFIDecryptedNote?] {
        guard spendingKey.count == 169 else {
            return Array(repeating: nil, count: outputs.count)
        }

        guard !outputs.isEmpty else {
            return []
        }

        // Pack all outputs into a single contiguous buffer
        // Format: [epk(32) + cmu(32) + ciphertext(580)] × output_count = 644 bytes each
        var packedOutputs = Data(capacity: outputs.count * 644)
        for output in outputs {
            guard output.epk.count == 32,
                  output.cmu.count == 32,
                  output.ciphertext.count >= 580 else {
                // Invalid output - add zeros to maintain alignment
                packedOutputs.append(Data(count: 644))
                continue
            }
            packedOutputs.append(output.epk)
            packedOutputs.append(output.cmu)
            packedOutputs.append(output.ciphertext.prefix(580))
        }

        // Allocate results buffer: 564 bytes per output
        // Format: [found(1) + diversifier(11) + value(8) + rcm(32) + memo(512)]
        var results = [UInt8](repeating: 0, count: outputs.count * 564)

        // Call the Rust parallel decryption function
        let decryptedCount = spendingKey.withUnsafeBytes { skPtr in
            packedOutputs.withUnsafeBytes { outputsPtr in
                zipherx_try_decrypt_notes_parallel(
                    skPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    outputsPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    outputs.count,
                    height,
                    &results
                )
            }
        }

        // Parse results
        var decryptedNotes: [FFIDecryptedNote?] = []
        for i in 0..<outputs.count {
            let offset = i * 564
            let found = results[offset]

            if found == 1 {
                // Extract decrypted note data
                let diversifier = Data(results[offset + 1 ..< offset + 12])
                let valueBytes = Data(results[offset + 12 ..< offset + 20])
                let value = valueBytes.withUnsafeBytes { $0.load(as: UInt64.self) }
                let rcm = Data(results[offset + 20 ..< offset + 52])
                let memo = Data(results[offset + 52 ..< offset + 564])

                decryptedNotes.append(FFIDecryptedNote(
                    diversifier: diversifier,
                    value: value,
                    rcm: rcm,
                    memo: memo
                ))
            } else {
                decryptedNotes.append(nil)
            }
        }

        // Log performance info on first use
        if decryptedCount > 0 {
            debugLog(.ffi, "🚀 Parallel decryption: \(decryptedCount)/\(outputs.count) notes found using \(getRayonThreads()) threads")
        }

        return decryptedNotes
    }

    // MARK: - CMU Position Lookup

    /// Find the position of a CMU in bundled CMU data (fast, no tree building)
    /// Returns the 0-indexed position, or nil if not found
    static func findCMUPosition(cmuData: Data, targetCMU: Data) -> UInt64? {
        guard targetCMU.count == 32 else {
            return nil
        }

        let position = cmuData.withUnsafeBytes { dataPtr in
            targetCMU.withUnsafeBytes { cmuPtr in
                zipherx_find_cmu_position(
                    dataPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    cmuData.count,
                    cmuPtr.baseAddress?.assumingMemoryBound(to: UInt8.self)
                )
            }
        }

        guard position != UInt64.max else {
            return nil
        }

        return position
    }

    // MARK: - Utility Functions

    /// Double hash data
    static func doubleHash(_ data: Data) -> Data? {
        var output = [UInt8](repeating: 0, count: 32)

        let success = data.withUnsafeBytes { ptr in
            zipherx_double_sha256(
                ptr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                data.count,
                &output
            )
        }

        guard success else {
            return nil
        }

        return Data(output)
    }

    // MARK: - Spending Key Encoding/Decoding

    /// Encode spending key as Bech32 string (secret-extended-key-main1...)
    static func encodeSpendingKey(_ spendingKey: Data) -> String? {
        guard spendingKey.count == 169 else {
            return nil
        }

        var buffer = [UInt8](repeating: 0, count: 512)

        let length = spendingKey.withUnsafeBytes { skPtr in
            zipherx_encode_spending_key(
                skPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                &buffer
            )
        }

        guard length > 0 else {
            return nil
        }

        return String(bytes: buffer.prefix(length), encoding: .utf8)
    }

    /// Decode Bech32 spending key string to bytes
    static func decodeSpendingKey(_ encoded: String) -> Data? {
        var output = [UInt8](repeating: 0, count: 169)

        let success = encoded.withCString { ptr in
            zipherx_decode_spending_key(ptr, &output)
        }

        guard success else {
            return nil
        }

        return Data(output)
    }

    // MARK: - Transaction Building

    /// Initialize the prover with Sapling parameters from file paths
    /// NOTE: May fail on macOS with Hardened Runtime - use initProverFromBytes instead
    static func initProver(spendParamsPath: String, outputParamsPath: String) -> Bool {
        return spendParamsPath.withCString { spendPtr in
            outputParamsPath.withCString { outputPtr in
                zipherx_init_prover(spendPtr, outputPtr)
            }
        }
    }

    /// Initialize the prover with Sapling parameters from raw byte arrays
    /// Use this when file access from Rust is restricted (e.g., macOS Hardened Runtime)
    /// Swift reads the files and passes the bytes to Rust
    static func initProverFromBytes(spendData: Data, outputData: Data) -> Bool {
        return spendData.withUnsafeBytes { spendPtr in
            guard let spendBaseAddress = spendPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return false
            }
            return outputData.withUnsafeBytes { outputPtr in
                guard let outputBaseAddress = outputPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return false
                }
                return zipherx_init_prover_from_bytes(
                    spendBaseAddress, spendData.count,
                    outputBaseAddress, outputData.count
                )
            }
        }
    }

    /// Build a complete shielded transaction
    /// Returns raw transaction bytes ready for broadcast
    static func buildTransaction(
        spendingKey: Data,
        toAddress: Data,
        amount: UInt64,
        memo: Data?,
        anchor: Data,
        witness: Data,
        noteValue: UInt64,
        noteRcm: Data,
        noteDiversifier: Data,
        chainHeight: UInt64
    ) -> Data? {
        guard spendingKey.count == 169,
              toAddress.count == 43,
              anchor.count == 32,
              noteRcm.count == 32,
              noteDiversifier.count == 11 else {
            return nil
        }

        var txOutput = [UInt8](repeating: 0, count: 10000)
        var txLen: Int = 0

        let memoData = memo ?? Data(repeating: 0, count: 512)
        guard memoData.count == 512 else { return nil }

        let success = spendingKey.withUnsafeBytes { skPtr in
            toAddress.withUnsafeBytes { toPtr in
                memoData.withUnsafeBytes { memoPtr in
                    anchor.withUnsafeBytes { anchorPtr in
                        witness.withUnsafeBytes { witnessPtr in
                            noteRcm.withUnsafeBytes { rcmPtr in
                                noteDiversifier.withUnsafeBytes { divPtr in
                                    zipherx_build_transaction(
                                        skPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                                        toPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                                        amount,
                                        memoPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                                        anchorPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                                        witnessPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                                        witness.count,
                                        noteValue,
                                        rcmPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                                        divPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                                        chainHeight,
                                        &txOutput,
                                        &txLen
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }

        guard success, txLen > 0 else {
            return nil
        }

        return Data(txOutput.prefix(txLen))
    }

    /// Spend information for multi-input transactions
    struct SpendInfoSwift {
        let witness: Data
        let value: UInt64
        let rcm: Data
        let diversifier: Data
    }

    /// Build a multi-input shielded transaction
    /// Returns tuple of (raw transaction bytes, array of nullifiers for spent notes)
    static func buildTransactionMulti(
        spendingKey: Data,
        toAddress: Data,
        amount: UInt64,
        memo: Data?,
        spends: [SpendInfoSwift],
        chainHeight: UInt64
    ) -> (txData: Data, nullifiers: [Data])? {
        guard spendingKey.count == 169,
              toAddress.count == 43,
              !spends.isEmpty,
              spends.count <= 100 else {
            print("❌ buildTransactionMulti: invalid inputs")
            return nil
        }

        // Validate all spends
        for (i, spend) in spends.enumerated() {
            guard spend.rcm.count == 32,
                  spend.diversifier.count == 11,
                  !spend.witness.isEmpty else {
                print("❌ buildTransactionMulti: invalid spend \(i)")
                return nil
            }
        }

        var txOutput = [UInt8](repeating: 0, count: 10000)
        var txLen: Int = 0
        var nullifiersOutput = [UInt8](repeating: 0, count: 32 * spends.count)

        let memoData = memo ?? Data(repeating: 0, count: 512)
        guard memoData.count == 512 else { return nil }

        // Create C-compatible SpendInfo structs
        // We need to keep references to the data alive during the FFI call
        var spendInfos: [SpendInfo] = []
        var witnessBuffers: [[UInt8]] = []
        var rcmBuffers: [[UInt8]] = []
        var divBuffers: [[UInt8]] = []

        for spend in spends {
            witnessBuffers.append(Array(spend.witness))
            rcmBuffers.append(Array(spend.rcm))
            divBuffers.append(Array(spend.diversifier))
        }

        // Create SpendInfo structs pointing to our buffers
        for i in 0..<spends.count {
            let info = SpendInfo(
                witness_data: UnsafePointer(witnessBuffers[i]),
                witness_len: witnessBuffers[i].count,
                note_value: spends[i].value,
                note_rcm: UnsafePointer(rcmBuffers[i]),
                note_diversifier: UnsafePointer(divBuffers[i])
            )
            spendInfos.append(info)
        }

        // Create array of pointers to SpendInfo
        var spendPtrs: [UnsafePointer<SpendInfo>?] = []
        for i in 0..<spendInfos.count {
            spendPtrs.append(withUnsafePointer(to: &spendInfos[i]) { $0 })
        }

        let success = spendingKey.withUnsafeBytes { skPtr in
            toAddress.withUnsafeBytes { toPtr in
                memoData.withUnsafeBytes { memoPtr in
                    spendPtrs.withUnsafeBufferPointer { spendsPtr in
                        zipherx_build_transaction_multi(
                            skPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                            toPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                            amount,
                            memoPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                            spendsPtr.baseAddress,
                            spends.count,
                            chainHeight,
                            &txOutput,
                            &txLen,
                            &nullifiersOutput
                        )
                    }
                }
            }
        }

        guard success, txLen > 0 else {
            return nil
        }

        // Extract nullifiers
        var nullifiers: [Data] = []
        for i in 0..<spends.count {
            let offset = i * 32
            let nfData = Data(nullifiersOutput[offset..<(offset + 32)])
            nullifiers.append(nfData)
        }

        return (Data(txOutput.prefix(txLen)), nullifiers)
    }

    /// Compute a value commitment
    static func computeValueCommitment(value: UInt64, rcv: Data) -> Data? {
        guard rcv.count == 32 else { return nil }

        var output = [UInt8](repeating: 0, count: 32)

        let success = rcv.withUnsafeBytes { rcvPtr in
            zipherx_compute_value_commitment(
                value,
                rcvPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                &output
            )
        }

        guard success else { return nil }
        return Data(output)
    }

    /// Generate a random scalar for value commitment
    static func randomScalar() -> Data? {
        var output = [UInt8](repeating: 0, count: 32)

        guard zipherx_random_scalar(&output) else {
            return nil
        }

        return Data(output)
    }

    /// Encrypt note plaintext
    static func encryptNote(
        diversifier: Data,
        pkD: Data,
        value: UInt64,
        rcm: Data,
        memo: Data
    ) -> (epk: Data, ciphertext: Data)? {
        guard diversifier.count == 11,
              pkD.count == 32,
              rcm.count == 32,
              memo.count == 512 else {
            return nil
        }

        var epkOutput = [UInt8](repeating: 0, count: 32)
        var encOutput = [UInt8](repeating: 0, count: 580)

        let success = diversifier.withUnsafeBytes { divPtr in
            pkD.withUnsafeBytes { pkdPtr in
                rcm.withUnsafeBytes { rcmPtr in
                    memo.withUnsafeBytes { memoPtr in
                        zipherx_encrypt_note(
                            divPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                            pkdPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                            value,
                            rcmPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                            memoPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                            &epkOutput,
                            &encOutput
                        )
                    }
                }
            }
        }

        guard success else { return nil }
        return (Data(epkOutput), Data(encOutput))
    }

    // MARK: - Commitment Tree Functions

    /// Initialize a new empty Sapling commitment tree
    static func treeInit() -> Bool {
        return zipherx_tree_init()
    }

    /// Add a note commitment (cmu) to the tree
    /// Returns the position of the added commitment, or UInt64.max on error
    static func treeAppend(cmu: Data) -> UInt64 {
        guard cmu.count == 32 else { return UInt64.max }

        return cmu.withUnsafeBytes { cmuPtr in
            zipherx_tree_append(cmuPtr.baseAddress?.assumingMemoryBound(to: UInt8.self))
        }
    }

    /// Add a note commitment from raw pointer (for bulk loading)
    /// Returns the position of the added commitment, or UInt64.max on error
    static func treeAppendRaw(cmu: UnsafePointer<UInt8>) -> UInt64 {
        return zipherx_tree_append(cmu)
    }

    /// Load a witness into memory for tracking/updating
    /// Returns the witness index or UInt64.max on error
    static func treeLoadWitness(witnessData: UnsafePointer<UInt8>, witnessLen: Int) -> UInt64 {
        return zipherx_tree_load_witness(witnessData, witnessLen)
    }

    /// Create a witness for the current position in the tree
    /// Call this right after appending a note that belongs to us
    /// Returns the witness index, or UInt64.max on error
    static func treeWitnessCurrent() -> UInt64 {
        return zipherx_tree_witness_current()
    }

    /// Get the current root of the tree
    static func treeRoot() -> Data? {
        var root = [UInt8](repeating: 0, count: 32)

        guard zipherx_tree_root(&root) else {
            return nil
        }

        return Data(root)
    }

    /// Get witness data for a specific witness index
    /// Returns 1028 bytes: 4 bytes position + 32*32 bytes merkle path
    static func treeGetWitness(index: UInt64) -> Data? {
        var witness = [UInt8](repeating: 0, count: 1028)

        guard zipherx_tree_get_witness(index, &witness) else {
            return nil
        }

        return Data(witness)
    }

    /// Get current tree size (number of commitments)
    static func treeSize() -> UInt64 {
        return zipherx_tree_size()
    }

    /// Serialize tree state for persistence
    static func treeSerialize() -> Data? {
        var buffer = [UInt8](repeating: 0, count: 100_000)
        var length: Int = 0

        guard zipherx_tree_serialize(&buffer, &length) else {
            return nil
        }

        return Data(buffer.prefix(length))
    }

    /// Deserialize tree state from persistence
    static func treeDeserialize(data: Data) -> Bool {
        return data.withUnsafeBytes { ptr in
            zipherx_tree_deserialize(
                ptr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                data.count
            )
        }
    }

    /// Load tree from raw CMUs file format
    /// Format: [count: u64 LE][cmu1: 32 bytes][cmu2: 32 bytes]...
    static func treeLoadFromCMUs(data: Data) -> Bool {
        return data.withUnsafeBytes { ptr in
            zipherx_tree_load_from_cmus(
                ptr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                data.count
            )
        }
    }

    /// Progress callback type for tree loading: (currentCMU, totalCMUs)
    typealias TreeLoadProgressCallback = (UInt64, UInt64) -> Void

    /// Global storage for progress callback (needed for C callback bridge)
    private static var treeLoadProgressCallback: TreeLoadProgressCallback?

    /// Load tree from raw CMUs file format with progress reporting
    /// Format: [count: u64 LE][cmu1: 32 bytes][cmu2: 32 bytes]...
    /// - Parameters:
    ///   - data: The bundled CMU file data
    ///   - onProgress: Called with (currentCMU, totalCMUs) approximately every 10000 CMUs
    /// - Returns: true if tree was loaded successfully
    static func treeLoadFromCMUsWithProgress(data: Data, onProgress: @escaping TreeLoadProgressCallback) -> Bool {
        // Store callback globally so C callback can access it
        treeLoadProgressCallback = onProgress

        // C callback that forwards to Swift
        let cCallback: @convention(c) (UInt64, UInt64) -> Void = { current, total in
            ZipherXFFI.treeLoadProgressCallback?(current, total)
        }

        let result = data.withUnsafeBytes { ptr in
            zipherx_tree_load_from_cmus_with_progress(
                ptr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                data.count,
                cCallback
            )
        }

        // Clear callback
        treeLoadProgressCallback = nil

        return result
    }

    /// Create a witness for a specific CMU from bundled CMU data
    /// This is used for notes discovered in PHASE 1 (parallel scan) within bundled tree range
    /// - Parameters:
    ///   - cmuData: The bundled CMU file data [count: u64][cmu1: 32]...
    ///   - targetCMU: The 32-byte CMU to create witness for
    /// - Returns: Tuple of (position, witness data) or nil on error
    static func treeCreateWitnessForCMU(cmuData: Data, targetCMU: Data) -> (position: UInt64, witness: Data)? {
        guard targetCMU.count == 32 else { return nil }

        var witnessBuffer = [UInt8](repeating: 0, count: 2000)
        var witnessLen: Int = 0

        let position = cmuData.withUnsafeBytes { cmuPtr in
            targetCMU.withUnsafeBytes { targetPtr in
                zipherx_tree_create_witness_for_cmu(
                    cmuPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    cmuData.count,
                    targetPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    &witnessBuffer,
                    &witnessLen
                )
            }
        }

        guard position != UInt64.max, witnessLen > 0 else { return nil }
        return (position: position, witness: Data(witnessBuffer.prefix(witnessLen)))
    }

    /// Create witnesses for MULTIPLE CMUs in a SINGLE tree pass (batch operation)
    /// This is MUCH faster than calling treeCreateWitnessForCMU multiple times
    /// because it only builds the tree ONCE instead of N times.
    ///
    /// For 9 notes with 1M CMUs: ~57 seconds total vs ~9 minutes (9 × 57s)
    ///
    /// - Parameters:
    ///   - cmuData: The bundled CMU file data [count: u64][cmu1: 32]...
    ///   - targetCMUs: Array of 32-byte CMUs to create witnesses for
    /// - Returns: Array of (position, witness) tuples, or nil for CMUs not found
    static func treeCreateWitnessesBatch(cmuData: Data, targetCMUs: [Data]) -> [(position: UInt64, witness: Data)?] {
        guard !targetCMUs.isEmpty else { return [] }

        // Validate all CMUs are 32 bytes
        for cmu in targetCMUs {
            guard cmu.count == 32 else {
                print("❌ Invalid CMU size: \(cmu.count)")
                return targetCMUs.map { _ in nil }
            }
        }

        let targetCount = targetCMUs.count

        // Pack all target CMUs into a single contiguous buffer
        var packedCMUs = Data(capacity: targetCount * 32)
        for cmu in targetCMUs {
            packedCMUs.append(cmu)
        }

        // Allocate output buffers
        var positions = [UInt64](repeating: UInt64.max, count: targetCount)
        var witnesses = [UInt8](repeating: 0, count: targetCount * 1028)

        let successCount = cmuData.withUnsafeBytes { cmuDataPtr in
            packedCMUs.withUnsafeBytes { targetsPtr in
                zipherx_tree_create_witnesses_batch(
                    cmuDataPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    cmuData.count,
                    targetsPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    targetCount,
                    &positions,
                    &witnesses
                )
            }
        }

        print("✅ Batch witness: \(successCount)/\(targetCount) witnesses created")

        // Parse results
        var results: [(position: UInt64, witness: Data)?] = []
        for i in 0..<targetCount {
            if positions[i] != UInt64.max {
                let witnessStart = i * 1028
                let witnessData = Data(witnesses[witnessStart..<(witnessStart + 1028)])
                results.append((position: positions[i], witness: witnessData))
            } else {
                results.append(nil)
            }
        }

        return results
    }

    /// Create witnesses for multiple CMUs using PARALLEL processing (Rayon)
    /// This is the FASTEST option - uses all CPU cores via Rayon work-stealing.
    /// Each witness gets its own thread building tree to that position.
    ///
    /// For 9 notes: uses 9 parallel threads, each builds tree to its position
    /// Expected speedup: 3-8x depending on CPU cores and note positions
    ///
    /// - Parameters:
    ///   - cmuData: The bundled CMU file data [count: u64][cmu1: 32]...
    ///   - targetCMUs: Array of 32-byte CMUs to create witnesses for
    /// - Returns: Array of (position, witness) tuples, or nil for CMUs not found
    static func treeCreateWitnessesParallel(cmuData: Data, targetCMUs: [Data]) -> [(position: UInt64, witness: Data)?] {
        guard !targetCMUs.isEmpty else { return [] }

        // Validate all CMUs are 32 bytes
        for cmu in targetCMUs {
            guard cmu.count == 32 else {
                print("❌ Invalid CMU size: \(cmu.count)")
                return targetCMUs.map { _ in nil }
            }
        }

        let targetCount = targetCMUs.count

        // Pack all target CMUs into a single contiguous buffer
        var packedCMUs = Data(capacity: targetCount * 32)
        for cmu in targetCMUs {
            packedCMUs.append(cmu)
        }

        // Allocate output buffers
        var positions = [UInt64](repeating: UInt64.max, count: targetCount)
        var witnesses = [UInt8](repeating: 0, count: targetCount * 1028)

        let startTime = Date()

        let successCount = packedCMUs.withUnsafeBytes { targetsPtr in
            cmuData.withUnsafeBytes { cmuDataPtr in
                zipherx_tree_create_witnesses_parallel(
                    targetsPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    targetCount,
                    cmuDataPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    cmuData.count,
                    &positions,
                    &witnesses
                )
            }
        }

        let elapsed = Date().timeIntervalSince(startTime)
        print("✅ Parallel witness: \(successCount)/\(targetCount) created in \(String(format: "%.1f", elapsed))s")

        // Parse results
        var results: [(position: UInt64, witness: Data)?] = []
        for i in 0..<targetCount {
            if positions[i] != UInt64.max {
                let witnessStart = i * 1028
                let witnessData = Data(witnesses[witnessStart..<(witnessStart + 1028)])
                results.append((position: positions[i], witness: witnessData))
            } else {
                results.append(nil)
            }
        }

        return results
    }

    // MARK: - OVK Output Recovery (Transaction History)

    /// Derive outgoing viewing key from spending key
    static func deriveOVK(from spendingKey: Data) -> Data? {
        guard spendingKey.count == 169 else {
            return nil
        }

        var ovk = [UInt8](repeating: 0, count: 32)

        let success = spendingKey.withUnsafeBytes { skPtr in
            zipherx_derive_ovk(
                skPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                &ovk
            )
        }

        guard success else {
            return nil
        }

        return Data(ovk)
    }

    /// Recovered output data from OVK decryption
    struct RecoveredOutput {
        let diversifier: Data   // 11 bytes
        let pkd: Data          // 32 bytes
        let value: UInt64      // zatoshis
        let rcm: Data          // 32 bytes
        let memo: Data         // 512 bytes
    }

    /// Try to recover a sent note using the outgoing viewing key
    /// Returns decrypted output data if this was a note we sent
    static func tryRecoverOutputWithOVK(
        ovk: Data,
        cv: Data,
        cmu: Data,
        epk: Data,
        encCiphertext: Data,
        outCiphertext: Data
    ) -> RecoveredOutput? {
        guard ovk.count == 32,
              cv.count == 32,
              cmu.count == 32,
              epk.count == 32,
              encCiphertext.count >= 580,
              outCiphertext.count >= 80 else {
            return nil
        }

        // Output buffer: 11 div + 32 pk_d + 8 value + 32 rcm + 512 memo = 595 bytes
        var output = [UInt8](repeating: 0, count: 620)

        let length = ovk.withUnsafeBytes { ovkPtr in
            cv.withUnsafeBytes { cvPtr in
                cmu.withUnsafeBytes { cmuPtr in
                    epk.withUnsafeBytes { epkPtr in
                        encCiphertext.withUnsafeBytes { encPtr in
                            outCiphertext.withUnsafeBytes { outPtr in
                                zipherx_try_recover_output_with_ovk(
                                    ovkPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                                    cvPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                                    cmuPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                                    epkPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                                    encPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                                    outPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                                    &output
                                )
                            }
                        }
                    }
                }
            }
        }

        guard length > 0 else {
            return nil
        }

        // Parse output: 11 div + 32 pk_d + 8 value + 32 rcm + 512 memo
        let diversifier = Data(output[0..<11])
        let pkd = Data(output[11..<43])
        let value = output[43..<51].withUnsafeBytes { $0.load(as: UInt64.self) }
        let rcm = Data(output[51..<83])
        let memo = Data(output[83..<595])

        return RecoveredOutput(
            diversifier: diversifier,
            pkd: pkd,
            value: value,
            rcm: rcm,
            memo: memo
        )
    }

    // MARK: - Equihash Proof-of-Work Verification

    /// Verify Equihash(200,9) solution for a block header
    /// - Parameters:
    ///   - header: 140-byte block header (includes 32-byte nonce at end)
    ///   - solution: Equihash solution bytes (typically 1344 bytes)
    /// - Returns: true if the Equihash solution is valid
    static func verifyEquihash(header: Data, solution: Data) -> Bool {
        guard header.count == 140 else {
            print("❌ verifyEquihash: header must be 140 bytes, got \(header.count)")
            return false
        }

        return header.withUnsafeBytes { headerPtr in
            solution.withUnsafeBytes { solutionPtr in
                zipherx_verify_equihash(
                    headerPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    solutionPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    solution.count
                )
            }
        }
    }

    /// Compute block hash (double SHA256) from header + solution
    /// - Parameters:
    ///   - header: 140-byte block header
    ///   - solution: Equihash solution bytes
    /// - Returns: 32-byte block hash in internal byte order, or nil on failure
    static func computeBlockHash(header: Data, solution: Data) -> Data? {
        guard header.count == 140 else {
            return nil
        }

        var hashOutput = [UInt8](repeating: 0, count: 32)

        let success = header.withUnsafeBytes { headerPtr in
            solution.withUnsafeBytes { solutionPtr in
                zipherx_compute_block_hash(
                    headerPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    solutionPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    solution.count,
                    &hashOutput
                )
            }
        }

        guard success else { return nil }
        return Data(hashOutput)
    }

    /// Verify a single block header (Equihash + compute hash)
    /// - Parameters:
    ///   - headerAndSolution: Full header data (140 bytes header + varint + solution)
    /// - Returns: 32-byte block hash if valid, or nil if invalid
    static func verifyBlockHeader(headerAndSolution: Data) -> Data? {
        guard headerAndSolution.count >= 141 else {
            print("❌ verifyBlockHeader: data too small (\(headerAndSolution.count) bytes)")
            return nil
        }

        var hashOutput = [UInt8](repeating: 0, count: 32)

        let success = headerAndSolution.withUnsafeBytes { dataPtr in
            zipherx_verify_block_header(
                dataPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                headerAndSolution.count,
                &hashOutput
            )
        }

        guard success else { return nil }
        return Data(hashOutput)
    }

    /// Verify a chain of block headers for continuity and valid PoW
    /// - Parameters:
    ///   - headers: Array of full header data (140 bytes + varint + solution each)
    ///   - expectedPrevHash: Expected prevHash of first header (32 bytes), or nil to skip first check
    /// - Returns: true if all headers valid and chain is continuous
    static func verifyHeaderChain(headers: [Data], expectedPrevHash: Data?) -> Bool {
        guard !headers.isEmpty else { return true }

        // Concatenate all headers into single buffer
        var concatenated = Data()
        var offsets: [Int] = []
        var sizes: [Int] = []

        for header in headers {
            offsets.append(concatenated.count)
            sizes.append(header.count)
            concatenated.append(header)
        }

        return concatenated.withUnsafeBytes { dataPtr in
            offsets.withUnsafeBytes { offsetsPtr in
                sizes.withUnsafeBytes { sizesPtr in
                    if let prevHash = expectedPrevHash, prevHash.count == 32 {
                        return prevHash.withUnsafeBytes { prevHashPtr in
                            zipherx_verify_header_chain(
                                dataPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                                headers.count,
                                prevHashPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                                offsetsPtr.baseAddress?.assumingMemoryBound(to: Int.self),
                                sizesPtr.baseAddress?.assumingMemoryBound(to: Int.self)
                            )
                        }
                    } else {
                        return zipherx_verify_header_chain(
                            dataPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                            headers.count,
                            nil,
                            offsetsPtr.baseAddress?.assumingMemoryBound(to: Int.self),
                            sizesPtr.baseAddress?.assumingMemoryBound(to: Int.self)
                        )
                    }
                }
            }
        }
    }

    // MARK: - VUL-002 FIX: Encrypted Key Operations
    // These functions pass encrypted spending keys to Rust where they are:
    // 1. Decrypted only within Rust
    // 2. Used for transaction building
    // 3. Immediately zeroed after use
    // This ensures the decrypted spending key never exists in Swift managed memory.

    /// Build a complete shielded transaction using encrypted spending key (VUL-002 secure)
    /// The spending key is encrypted with AES-GCM-256 and decrypted only in Rust
    /// Returns raw transaction bytes ready for broadcast
    static func buildTransactionEncrypted(
        encryptedSpendingKey: Data,  // 197 bytes: nonce(12) + ciphertext(169) + tag(16)
        encryptionKey: Data,          // 32 bytes: AES-256 key
        toAddress: Data,
        amount: UInt64,
        memo: Data?,
        anchor: Data,
        witness: Data,
        noteValue: UInt64,
        noteRcm: Data,
        noteDiversifier: Data,
        chainHeight: UInt64
    ) -> Data? {
        guard encryptedSpendingKey.count == 197,
              encryptionKey.count == 32,
              toAddress.count == 43,
              anchor.count == 32,
              noteRcm.count == 32,
              noteDiversifier.count == 11 else {
            print("❌ buildTransactionEncrypted: invalid inputs")
            return nil
        }

        var txOutput = [UInt8](repeating: 0, count: 10000)
        var txLen: Int = 0

        let memoData = memo ?? Data(repeating: 0, count: 512)
        guard memoData.count == 512 else { return nil }

        let success = encryptedSpendingKey.withUnsafeBytes { encSkPtr in
            encryptionKey.withUnsafeBytes { encKeyPtr in
                toAddress.withUnsafeBytes { toPtr in
                    memoData.withUnsafeBytes { memoPtr in
                        anchor.withUnsafeBytes { anchorPtr in
                            witness.withUnsafeBytes { witnessPtr in
                                noteRcm.withUnsafeBytes { rcmPtr in
                                    noteDiversifier.withUnsafeBytes { divPtr in
                                        zipherx_build_transaction_encrypted(
                                            encSkPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                                            encryptedSpendingKey.count,
                                            encKeyPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                                            toPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                                            amount,
                                            memoPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                                            anchorPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                                            witnessPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                                            witness.count,
                                            noteValue,
                                            rcmPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                                            divPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                                            chainHeight,
                                            &txOutput,
                                            &txLen
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        guard success, txLen > 0 else {
            return nil
        }

        return Data(txOutput.prefix(txLen))
    }

    /// Build a multi-input shielded transaction using encrypted spending key (VUL-002 secure)
    /// The spending key is encrypted with AES-GCM-256 and decrypted only in Rust
    /// Returns tuple of (raw transaction bytes, array of nullifiers for spent notes)
    static func buildTransactionMultiEncrypted(
        encryptedSpendingKey: Data,  // 197 bytes: nonce(12) + ciphertext(169) + tag(16)
        encryptionKey: Data,          // 32 bytes: AES-256 key
        toAddress: Data,
        amount: UInt64,
        memo: Data?,
        spends: [SpendInfoSwift],
        chainHeight: UInt64
    ) -> (txData: Data, nullifiers: [Data])? {
        guard encryptedSpendingKey.count == 197,
              encryptionKey.count == 32,
              toAddress.count == 43,
              !spends.isEmpty,
              spends.count <= 100 else {
            print("❌ buildTransactionMultiEncrypted: invalid inputs")
            return nil
        }

        // Validate all spends
        for (i, spend) in spends.enumerated() {
            guard spend.rcm.count == 32,
                  spend.diversifier.count == 11,
                  !spend.witness.isEmpty else {
                print("❌ buildTransactionMultiEncrypted: invalid spend \(i)")
                return nil
            }
        }

        var txOutput = [UInt8](repeating: 0, count: 10000)
        var txLen: Int = 0
        var nullifiersOutput = [UInt8](repeating: 0, count: 32 * spends.count)

        let memoData = memo ?? Data(repeating: 0, count: 512)
        guard memoData.count == 512 else { return nil }

        // Create C-compatible SpendInfo structs
        var spendInfos: [SpendInfo] = []
        var witnessBuffers: [[UInt8]] = []
        var rcmBuffers: [[UInt8]] = []
        var divBuffers: [[UInt8]] = []

        for spend in spends {
            witnessBuffers.append(Array(spend.witness))
            rcmBuffers.append(Array(spend.rcm))
            divBuffers.append(Array(spend.diversifier))
        }

        // Create SpendInfo structs pointing to our buffers
        for i in 0..<spends.count {
            let info = SpendInfo(
                witness_data: UnsafePointer(witnessBuffers[i]),
                witness_len: witnessBuffers[i].count,
                note_value: spends[i].value,
                note_rcm: UnsafePointer(rcmBuffers[i]),
                note_diversifier: UnsafePointer(divBuffers[i])
            )
            spendInfos.append(info)
        }

        // Create array of pointers to SpendInfo
        var spendPtrs: [UnsafePointer<SpendInfo>?] = []
        for i in 0..<spendInfos.count {
            spendPtrs.append(withUnsafePointer(to: &spendInfos[i]) { $0 })
        }

        let success = encryptedSpendingKey.withUnsafeBytes { encSkPtr in
            encryptionKey.withUnsafeBytes { encKeyPtr in
                toAddress.withUnsafeBytes { toPtr in
                    memoData.withUnsafeBytes { memoPtr in
                        spendPtrs.withUnsafeBufferPointer { spendsPtr in
                            zipherx_build_transaction_multi_encrypted(
                                encSkPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                                encryptedSpendingKey.count,
                                encKeyPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                                toPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                                amount,
                                memoPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                                spendsPtr.baseAddress,
                                spends.count,
                                chainHeight,
                                &txOutput,
                                &txLen,
                                &nullifiersOutput
                            )
                        }
                    }
                }
            }
        }

        guard success, txLen > 0 else {
            return nil
        }

        // Extract nullifiers
        var nullifiers: [Data] = []
        for i in 0..<spends.count {
            let offset = i * 32
            let nfData = Data(nullifiersOutput[offset..<(offset + 32)])
            nullifiers.append(nfData)
        }

        return (Data(txOutput.prefix(txLen)), nullifiers)
    }
}
