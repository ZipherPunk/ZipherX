# Sapling Note Decryption - Byte Order Fix Analysis

## Summary

ZipherX was showing 0 balance despite having 0.018 ZCL across 3 confirmed shielded transactions. The root cause was **incorrect byte order handling for EPK (ephemeral public key)** when parsing from JSON RPC responses.

## The Problem

ChaCha20Poly1305 AEAD decryption was failing with authentication tag mismatch. Raw decryption showed invalid lead byte (0x76 instead of 0x01/0x02).

### Confirmed Transactions

| TXID | Amount | OutIndex |
|------|--------|----------|
| `9724d0dd5525c9ff21c3a1b1ed072311988fb0e5305a9d7526950ace6a6ee703` | 0.003 ZCL | 0 |
| `a6dffa2698b10e0600c809a673877a273cb324bd5eac7d4ba36a59c0853fe3a1` | 0.01 ZCL | 0 |
| `2953a6defcefc734adeaa0e64ef4fc77a7b4636d0c8cb707177818c631fc20bf` | 0.005 ZCL | 0 |

**Total: 0.018 ZCL** - correctly shown by `zclassic-cli z_getbalance`

## Root Cause

### uint256::GetHex() Reverses Byte Order

In `/zclassic/src/uint256.cpp` (lines 21-27):

```cpp
std::string base_blob<BITS>::GetHex() const
{
    char psz[sizeof(data) * 2 + 1];
    for (unsigned int i = 0; i < sizeof(data); i++)
        sprintf(psz + i * 2, "%02x", data[sizeof(data) - i - 1]);  // REVERSES!
    return std::string(psz, psz + sizeof(data) * 2);
}
```

This means:
- **Internal storage** (wire format): Little-endian
- **Display format** (GetHex/JSON): Big-endian (human-readable)

### EPK Byte Order Issue

| Format | EPK Value |
|--------|-----------|
| Wire format (correct) | `4dab7b4182b77943f923e50eae6ac035b3bc72ed7fcf0ac6019508886a0c5e6d` |
| Display format (JSON) | `6d5e0c6a88089501c60acf7fed72bcb335c06aae0ee523f94379b782417bab4d` |

We were passing the display format directly to `librustzcash_sapling_ka_agree()`, which expects wire format.

### IVK Does NOT Need Reversal

The IVK (incoming viewing key) is derived via `librustzcash_crh_ivk()` which outputs in the correct little-endian format. The display format shown by debugging IS the wire format.

## The Fix

When parsing EPK from JSON RPC responses (`getrawtransaction`), reverse the byte order:

```rust
// EPK from JSON API - reverse from display to wire format
let epk_display = "6d5e0c6a88089501c60acf7fed72bcb335c06aae0ee523f94379b782417bab4d";
let epk_bytes: [u8; 32] = {
    let mut bytes = [0u8; 32];
    let decoded = hex::decode(epk_display).unwrap();
    // Reverse for wire format
    for i in 0..32 {
        bytes[i] = decoded[31 - i];
    }
    bytes
};
```

## Verification Results

After applying the fix:

```
Testing Sapling note decryption...

IVK (wire format): 6ac06a1403444ab3855421fe181a586bac7ee65946f6f394bb2b49ac4bbc3705
EPK (wire format): 4dab7b4182b77943f923e50eae6ac035b3bc72ed7fcf0ac6019508886a0c5e6d

Shared secret: 34f95b0eeef73d90ee304e0454675021813b832d79eb5338741cc34fc5499a12
KDF key: 9d2f35a0ba1ec845a6b87865ed634c034ee23250e741b536d584de88f47f46a8

✅ Decryption SUCCESS!
Plaintext length: 564 bytes
Lead byte: 0x01
Value: 300000 zatoshi (0.00300000 ZCL)
```

**Decrypted value matches the first transaction amount (0.003 ZCL)!**

## Affected Components

### 1. Note Scanning / Trial Decryption
Any code that reads `vShieldedOutput[].epk` from JSON and passes to decryption.

### 2. Values That Need Byte Reversal
- **EPK** (ephemeral public key) - from `getrawtransaction`
- **cv** (value commitment) - if used
- **cm** (note commitment) - if used
- **cmu** - if read from JSON

### 3. Values That Do NOT Need Reversal
- **IVK** - output from `librustzcash_crh_ivk` is already correct
- **encCiphertext** - raw bytes, not a uint256
- **outCiphertext** - raw bytes, not a uint256

## Implementation in ZipherX

### Location
`/Users/chris/ZipherX/Libraries/zipherx-ffi/src/lib.rs`

### Required Changes

1. Add byte-reversal helper:
```rust
fn reverse_bytes(hex: &str) -> Result<[u8; 32], Box<dyn Error>> {
    let decoded = hex::decode(hex)?;
    if decoded.len() != 32 {
        return Err("Invalid length".into());
    }
    let mut bytes = [0u8; 32];
    for i in 0..32 {
        bytes[i] = decoded[31 - i];
    }
    Ok(bytes)
}
```

2. Apply to EPK parsing in note scanning:
```rust
// When parsing shielded output from JSON
let epk_bytes = reverse_bytes(&output.epk)?;  // Reverse for wire format
```

3. Keep IVK as-is (no reversal needed).

## Sapling Decryption Flow (Correct)

```
1. Parse EPK from JSON         → Reverse bytes (display → wire)
2. Parse IVK from derivation   → Use as-is (already wire format)
3. ECDH key agreement          → ka = [ivk] * clear_cofactor(epk)
4. KDF                         → key = BLAKE2b("Zcash_SaplingKDF", ka || epk)
5. ChaCha20Poly1305 decrypt    → plaintext = decrypt(key, nonce=0, ciphertext)
6. Parse note plaintext        → diversifier, value, rcm, memo
```

## Testing Checklist

- [x] Single note decryption (tx 9724d0dd) - 0.003 ZCL
- [ ] Second transaction (tx a6dffa26) - 0.01 ZCL
- [ ] Third transaction (tx 2953a6de) - 0.005 ZCL
- [ ] Total balance shows 0.018 ZCL
- [ ] Note commitment verification passes
- [ ] Diversifier matches address

## Lessons Learned

1. **Always check byte order** when crossing boundaries between JSON APIs and cryptographic libraries
2. **uint256 display format ≠ wire format** in Zcash/Zclassic codebase
3. **IVK and EPK have different sources** - derivation vs. transaction parsing
4. **Test with real blockchain data** to catch these subtle issues

## References

- Zclassic uint256.cpp - GetHex() implementation
- ZIP-32 - Extended spending keys
- Zcash Protocol Spec - Sapling note encryption
- librustzcash - `sapling_ka_agree` function
