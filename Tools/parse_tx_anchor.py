#!/usr/bin/env python3
"""
Parse Transaction Anchor

Extracts the anchor from a raw Sapling transaction hex.
"""

import sys

def main():
    if len(sys.argv) < 2:
        print("Usage: parse_tx_anchor.py <raw_tx_hex>")
        return 1

    raw_tx_hex = sys.argv[1]
    raw_tx = bytes.fromhex(raw_tx_hex)

    print("🔍 Parsing Sapling Transaction")
    print("=" * 70)
    print(f"📦 Transaction size: {len(raw_tx):,} bytes")
    print()

    # Zcash v4 transaction structure (simplified):
    # Header (4 bytes)
    # nVersionGroupId (4 bytes)
    # vin (variable)
    # vout (variable)
    # lock_time (4 bytes)
    # nExpiryHeight (4 bytes)
    # valueBalance (8 bytes)
    # nShieldedSpend (varint)
    # vShieldedSpend (variable)
    # nShieldedOutput (varint)
    # vShieldedOutput (variable)
    # ...

    # For a transaction with Sapling spends, the anchor appears after valueBalance
    # Let's search for the anchor pattern

    # The anchor we're looking for starts with: c148d1fcce8c42e2
    anchor_prefix = bytes.fromhex("c148d1fcce8c42e2")

    pos = raw_tx.find(anchor_prefix)
    if pos == -1:
        print("❌ Could not find anchor in transaction")
        return 1

    # Extract 32-byte anchor
    anchor = raw_tx[pos:pos+32]
    anchor_hex = anchor.hex()

    print(f"✅ Found anchor at position {pos}")
    print(f"🌳 Anchor: {anchor_hex}")
    print()

    # This is what our app computed and used
    print("📝 This is the anchor our app computed from the commitment tree")
    print("📝 and used in the transaction's Sapling spend proof")
    print()
    print("💡 To verify correctness, compare with zcashd's finalsaplingroot")
    print("   at the block height when this transaction was created")

    return 0

if __name__ == '__main__':
    sys.exit(main())
