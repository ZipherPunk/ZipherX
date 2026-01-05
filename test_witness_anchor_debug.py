#!/usr/bin/env python3
"""
Debug script to investigate witness/anchor mismatch issue.

The problem:
- Preparation phase: anchor 9012cd8c... ✅
- Actual send phase: anchor 91941c23... ❌

Both should use same witness and same anchor, but produce different results.
"""

import sqlite3
import struct
import sys
import os

WALLET_DB = os.path.expanduser("~/Library/Application Support/ZipherX/zipherx_wallet.db")
HEADERS_DB = os.path.expanduser("~/Library/Application Support/ZipherX/zipherx_headers.db")

def parse_compact_size(data, offset):
    """Parse Bitcoin-style compact size integer"""
    if offset >= len(data):
        return 0, offset
    first_byte = data[offset]
    if first_byte < 0xFD:
        return first_byte, offset + 1
    elif first_byte == 0xFD:
        if offset + 3 > len(data):
            return 0, offset
        value = struct.unpack("<H", data[offset+1:offset+3])[0]
        return value, offset + 3
    elif first_byte == 0xFE:
        if offset + 5 > len(data):
            return 0, offset
        value = struct.unpack("<I", data[offset+1:offset+5])[0]
        return value, offset + 5
    else:
        if offset + 9 > len(data):
            return 0, offset
        value = struct.unpack("<Q", data[offset+1:offset+9])[0]
        return value, offset + 9

def analyze_witness_structure(witness_bytes):
    """Analyze witness structure to detect corruption"""
    print("\n" + "="*80)
    print("WITNESS STRUCTURE ANALYSIS")
    print("="*80)

    if len(witness_bytes) < 9:
        print("❌ Witness too short to analyze")
        return None

    # Parse position
    offset = 0
    position = struct.unpack("<Q", witness_bytes[offset:offset+8])[0]
    print(f"Position: {position}")
    offset += 8

    # Parse num_nodes
    num_nodes, offset = parse_compact_size(witness_bytes, offset)
    print(f"Num nodes: {num_nodes}")

    # Check path nodes
    expected_path_bytes = num_nodes * 32
    actual_path_bytes = len(witness_bytes) - offset

    print(f"Expected path bytes: {expected_path_bytes}")
    print(f"Actual remaining bytes: {actual_path_bytes}")

    if actual_path_bytes < expected_path_bytes:
        print(f"❌ Witness is truncated! Missing {expected_path_bytes - actual_path_bytes} bytes")

    # Check first and last path nodes
    if num_nodes > 0:
        first_node = witness_bytes[offset:offset+32]
        print(f"First path node: {first_node.hex().upper()}")

        if actual_path_bytes >= 32:
            last_node_offset = offset + (num_nodes - 1) * 32
            if last_node_offset + 32 <= len(witness_bytes):
                last_node = witness_bytes[last_node_offset:last_node_offset+32]
                print(f"Last path node: {last_node.hex().upper()}")
            else:
                print(f"❌ Last path node would be at offset {last_node_offset}, but witness ends at {len(witness_bytes)}")
                print(f"   Last 32 bytes: {witness_bytes[-32:].hex().upper()}")

    # Check witness ends with zeros
    if witness_bytes[-32:] == b'\x00' * 32:
        print("❌ Witness ends with 32 zeros - PATH NODES CORRUPTED!")
        print("   This means the last path node(s) are all zeros")
        print("   When Zcash builder computes root from these corrupted nodes, it will be wrong!")

    return position, num_nodes

def get_header_sapling_root(height):
    """Get sapling_root from HeaderStore"""
    try:
        conn = sqlite3.connect(HEADERS_DB)
        cursor = conn.cursor()
        cursor.execute("SELECT sapling_root FROM headers WHERE height = ?", (height,))
        row = cursor.fetchone()
        conn.close()

        if row and row[0]:
            anchor_str = row[0]
            if isinstance(anchor_str, bytes):
                return anchor_str
            return bytes.fromhex(anchor_str)
        return None
    except Exception as e:
        print(f"Error getting header: {e}")
        return None

def main():
    print("="*80)
    print("WITNESS/ANCHOR MISMATCH DEBUG")
    print("="*80)

    # Get largest spendable note
    conn = sqlite3.connect(WALLET_DB)
    cursor = conn.cursor()

    cursor.execute("""
        SELECT id, received_height, value, hex(witness), length(witness),
               hex(anchor), hex(cmu)
        FROM notes
        WHERE is_spent = 0 AND witness IS NOT NULL
        ORDER BY value DESC
        LIMIT 1
    """)

    note = cursor.fetchone()
    conn.close()

    if not note:
        print("❌ No spendable notes found")
        return

    note_id, note_height, value, witness_hex, witness_len, anchor_hex, cmu_hex = note

    print(f"\nNote ID: {note_id}")
    print(f"Height: {note_height}")
    print(f"Value: {value} zatoshis ({value / 100000000:.8f} ZCL)")
    print(f"Witness: {witness_len} bytes")
    print(f"Stored anchor: {anchor_hex[:64].upper()}...")
    print(f"CMU: {cmu_hex[:64].upper()}...")

    witness_bytes = bytes.fromhex(witness_hex)
    anchor_bytes = bytes.fromhex(anchor_hex)
    cmu_bytes = bytes.fromhex(cmu_hex)

    # Analyze witness structure
    analyze_witness_structure(witness_bytes)

    # Get header anchor
    header_anchor = get_header_sapling_root(note_height)
    if not header_anchor:
        print(f"\n❌ No header in HeaderStore at height {note_height}")
        return

    print(f"\nHeader anchor: {header_anchor.hex().upper()}")

    # Compare stored anchor with header anchor
    print("\n" + "="*80)
    print("ANCHOR COMPARISON")
    print("="*80)

    if anchor_bytes == header_anchor:
        print("✅ Stored anchor MATCHES header anchor")
    else:
        print("❌ Stored anchor DIFFERS from header anchor")
        print(f"   Stored:  {anchor_bytes.hex().upper()}")
        print(f"   Header:  {header_anchor.hex().upper()}")

    # Key insight: The witness root is computed from PATH NODES
    # If path nodes are corrupted (zeros at end), the computed root will differ
    # even if the stored anchor is correct!

    print("\n" + "="*80)
    print("KEY INSIGHT")
    print("="*80)
    print("""
The witness has THREE parts:
1. Position (8 bytes) - where in the tree this CMU is
2. Path nodes (32 bytes each) - siblings needed to compute root
3. (Optional) Cached root - might be stored separately

When Swift code calls witnessGetRoot():
- It deserializes the witness
- Computes root by combining path nodes
- Returns this computed root

When Rust code builds transaction:
- It deserializes the SAME witness
- Computes root by combining path nodes
- Uses this root to build the zk-SNARK proof

If path nodes are CORRUPTED (e.g., last 32 bytes are zeros):
- witnessGetRoot() will compute WRONG root
- Transaction will be built with WRONG anchor in proof
- But binding sig might still pass (if anchor in tx data is correct)

The FIX:
- Rebuild witness from scratch using CMU file + blockchain data
- This ensures path nodes are correct
- Then witness root will match header anchor
- And transaction will be valid
    """)

if __name__ == "__main__":
    main()
