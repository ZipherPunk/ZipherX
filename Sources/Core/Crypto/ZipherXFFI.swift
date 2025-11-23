import Foundation

/// Swift wrapper for ZipherX Rust FFI functions
enum ZipherXFFI {

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

    /// Compute nullifier for a note
    static func computeNullifier(
        viewingKey: Data,
        diversifier: Data,
        value: UInt64,
        rcm: Data,
        position: UInt64
    ) -> Data? {
        guard viewingKey.count == 32,
              diversifier.count == 11,
              rcm.count == 32 else {
            return nil
        }

        var nullifier = [UInt8](repeating: 0, count: 32)

        let success = viewingKey.withUnsafeBytes { vkPtr in
            diversifier.withUnsafeBytes { divPtr in
                rcm.withUnsafeBytes { rcmPtr in
                    zipherx_compute_nullifier(
                        vkPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
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

    // MARK: - Utility Functions

    /// Get FFI library version
    static var version: UInt32 {
        zipherx_version()
    }

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

    /// Initialize the prover with Sapling parameters
    /// Must be called before building transactions
    static func initProver(spendParamsPath: String, outputParamsPath: String) -> Bool {
        return spendParamsPath.withCString { spendPtr in
            outputParamsPath.withCString { outputPtr in
                zipherx_init_prover(spendPtr, outputPtr)
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
        noteDiversifier: Data
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
}
