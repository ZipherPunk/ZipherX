#!/usr/bin/env python3
"""
Analyze the transaction structure to find the correct anchor position
"""

def analyze_tx_structure(tx_hex):
    """Parse transaction hex to find anchor"""
    tx_bytes = bytes.fromhex(tx_hex)
    tx_len = len(tx_bytes)

    print("="*80)
    print("TRANSACTION STRUCTURE ANALYSIS")
    print("="*80)
    print(f"Transaction length: {tx_len} bytes")

    # Version (first 4 bytes, little endian)
    version = int.from_bytes(tx_bytes[0:4], 'little')
    print(f"\nVersion: {version} (0x{version:08x})")

    # Version group ID (next 4 bytes)
    version_group = int.from_bytes(tx_bytes[4:8], 'little')
    print(f"Version group ID: {version_group} (0x{version_group:08x})")

    # Check for transparent inputs (compact size)
    # For Sapling-only tx, this should be 0x00
    offset = 8
    first_byte = tx_bytes[offset]
    if first_byte < 0xFD:
        num_tin = first_byte
        offset += 1
    elif first_byte == 0xFD:
        num_tin = int.from_bytes(tx_bytes[offset+1:offset+3], 'little')
        offset += 3
    else:
        num_tin = 0
        offset += 1

    print(f"\nTransparent inputs: {num_tin}")

    # Check for transparent outputs (compact size)
    first_byte = tx_bytes[offset]
    if first_byte < 0xFD:
        num_tout = first_byte
        offset += 1
    elif first_byte == 0xFD:
        num_tout = int.from_bytes(tx_bytes[offset+1:offset+3], 'little')
        offset += 3
    else:
        num_tout = 0
        offset += 1

    print(f"Transparent outputs: {num_tout}")

    # Lock time (4 bytes)
    lock_time = int.from_bytes(tx_bytes[offset:offset+4], 'little')
    offset += 4
    print(f"Lock time: {lock_time}")

    # Sapling bundle (version byte + spends + outputs + valueBalance + anchor + bindingSig)
    sapling_version = tx_bytes[offset]
    offset += 1
    print(f"\nSapling version: {sapling_version}")

    # Number of spends (compact size)
    first_byte = tx_bytes[offset]
    if first_byte < 0xFD:
        num_spends = first_byte
        offset += 1
    else:
        num_spends = 1  # Assume
        offset += 1

    print(f"Sapling spends: {num_spends}")

    # For 1 spend, skip to anchor
    # Each spend: 192 bytes (nullifier + rk + proof + spendAuthSig)
    # But the exact structure is complex...

    # Let's just look at the END of the transaction
    print(f"\n" + "="*80)
    print("LAST 100 BYTES OF TRANSACTION")
    print("="*80)

    last_100 = tx_bytes[-100:]
    for i in range(0, len(last_100), 32):
        chunk = last_100[i:i+32]
        hex_str = chunk.hex().upper()
        print(f"Offset {tx_len - 100 + i}: {hex_str}")

    # Expected structure at end:
    # [valueBalance (8)] [anchor (32)] [bindingSig (64)]
    print(f"\n" + "="*80)
    print("EXPECTED TRANSACTION END STRUCTURE")
    print("="*80)
    print("Offset -96: valueBalance (8 bytes)")
    print("Offset -88: anchor (32 bytes)")
    print("Offset -56: bindingSig (64 bytes)")
    print(f"Offset 0: end of transaction")

    # Try extracting at expected position
    anchor_offset = tx_len - 88  # valueBalance(8) + anchor(32) + bindingSig(64) = 104, but anchor is at -88
    anchor = tx_bytes[anchor_offset:anchor_offset+32]
    print(f"\nExtracted anchor (offset -88): {anchor.hex().upper()}")

    # Also try at -96 (in case valueBalance is not there or is different size)
    anchor2 = tx_bytes[tx_len-96:tx_len-64]
    print(f"Extracted anchor (offset -96): {anchor2.hex().upper()}")

    # And the binding sig
    binding_sig = tx_bytes[-64:]
    print(f"\nBinding sig (last 64 bytes): {binding_sig.hex().upper()}")

# Expected anchor
print("="*80)
print("EXPECTED ANCHOR FROM BUILD LOG")
print("="*80)
print("9012CD8C19E3F36C4E299D423E4BFAD1568AEB3CD5CFCE4E94D111BFAFAB5525")
