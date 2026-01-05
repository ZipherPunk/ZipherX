#!/usr/bin/env python3
"""
Deep analysis of IncrementalWitness structure.

Format:
1. CommitmentTree (tree):
   - Optional<Node> left
   - Optional<Node> right
   - Vector<Optional<Node>> parents
2. Vector<Node> filled
3. Optional<CommitmentTree> cursor

If 'tree' is intact, root() will work even if 'filled' is corrupted!
"""

import sqlite3
import struct
import sys
import os

WALLET_DB = os.path.expanduser("~/Library/Application Support/ZipherX/zipherx_wallet.db")

def parse_optional_node(data, offset):
    """Parse Optional<Node> - 1 byte flag + 32 bytes node if present"""
    if offset >= len(data):
        return None, 0, offset
    flag = data[offset]
    if flag == 0:
        return None, flag, offset + 1
    elif flag == 1 and offset + 33 <= len(data):
        node = data[offset+1:offset+33]
        return node, flag, offset + 33
    else:
        return None, flag, offset

def parse_vector(data, offset):
    """Parse Vector<Optional<Node>>"""
    if offset >= len(data):
        return [], offset

    # Read compact size for vector length
    first_byte = data[offset]
    if first_byte < 0xFD:
        count = first_byte
        offset += 1
    elif first_byte == 0xFD and offset + 3 <= len(data):
        count = struct.unpack("<H", data[offset+1:offset+3])[0]
        offset += 3
    elif first_byte == 0xFE and offset + 5 <= len(data):
        count = struct.unpack("<I", data[offset+1:offset+5])[0]
        offset += 5
    else:
        count = 0
        offset += 1

    nodes = []
    for _ in range(min(count, 100)):  # Limit to 100 for safety
        node, flag, offset = parse_optional_node(data, offset)
        if flag is None:
            break
        nodes.append(node)

    return nodes, offset, count

def analyze_witness_deep(witness_bytes):
    """Deep analysis of witness structure"""
    print("\n" + "="*80)
    print("DEEP WITNESS STRUCTURE ANALYSIS")
    print("="*80)

    offset = 0

    # Part 1: CommitmentTree (tree)
    print("\n--- Part 1: CommitmentTree (tree) ---")

    # Left
    left, flag, offset = parse_optional_node(witness_bytes, offset)
    if flag == 0:
        print(f"Left: None (flag={flag})")
    elif left:
        print(f"Left: Present (flag={flag}) - {len(left)} bytes")
        print(f"  Value: {left.hex().upper()}")
    else:
        print(f"Left: PARSE ERROR at offset {offset}")
        return

    # Right
    right, flag, offset = parse_optional_node(witness_bytes, offset)
    if flag == 0:
        print(f"Right: None (flag={flag})")
    elif right:
        print(f"Right: Present (flag={flag}) - {len(right)} bytes")
        print(f"  Value: {right.hex().upper()}")
    else:
        print(f"Right: PARSE ERROR at offset {offset}")
        return

    # Parents vector
    parents, offset, parent_count = parse_vector(witness_bytes, offset)
    print(f"Parents: {parent_count} nodes, parsed {len(parents)}")
    if parents:
        print(f"  First parent: {parents[0].hex().upper() if parents[0] else 'None'}")
        if len(parents) > 1:
            print(f"  Last parent: {parents[-1].hex().upper() if parents[-1] else 'None'}")

    tree_end_offset = offset

    # Part 2: filled vector
    print(f"\n--- Part 2: Vector<Node> filled ---")
    print(f"Offset: {offset}/{len(witness_bytes)}")

    filled, offset, filled_count = parse_vector(witness_bytes, offset)
    print(f"Filled: {filled_count} nodes, parsed {len(filled)}")
    if filled:
        print(f"  First filled: {filled[0].hex().upper() if filled[0] else 'None'}")
        if len(filled) > 1:
            print(f"  Last filled: {filled[-1].hex().upper() if filled[-1] else 'None'}")

    filled_end_offset = offset

    # Part 3: cursor (optional CommitmentTree)
    print(f"\n--- Part 3: Optional<CommitmentTree> cursor ---")
    print(f"Offset: {offset}/{len(witness_bytes)}")

    if offset < len(witness_bytes):
        cursor_flag = witness_bytes[offset]
        offset += 1
        print(f"Cursor flag: {cursor_flag}")

        if cursor_flag == 1 and offset < len(witness_bytes):
            # Parse cursor's left
            cursor_left, flag, offset = parse_optional_node(witness_bytes, offset)
            if cursor_left:
                print(f"  Cursor left: {cursor_left.hex().upper()}")

            # Parse cursor's right
            cursor_right, flag, offset = parse_optional_node(witness_bytes, offset)
            if cursor_right:
                print(f"  Cursor right: {cursor_right.hex().upper()}")

            # Parse cursor's parents
            cursor_parents, offset, cursor_parent_count = parse_vector(witness_bytes, offset)
            print(f"  Cursor parents: {cursor_parent_count} nodes")

    print(f"\n--- Summary ---")
    print(f"Tree part ends at: {tree_end_offset}")
    print(f"Filled part ends at: {filled_end_offset}")
    print(f"Total witness size: {len(witness_bytes)}")
    print(f"Remaining bytes: {len(witness_bytes) - offset}")

    # Check if tree part (used for root()) is intact
    print(f"\n--- Root Computation Analysis ---")
    if left and right:
        print("✅ Tree has both left and right children")
        print("   → root() can compute from tree structure")
        print("   → Even if 'filled' vector is corrupted!")

    if parents:
        print(f"✅ Tree has {len(parents)} parents")
        print("   → Full path from leaf to root exists")

    # Check corruption
    if filled_end_offset > len(witness_bytes):
        print(f"\n❌ CORRUPTION: Parsing went beyond witness size!")
        print(f"   Parsed to {filled_end_offset}, but witness is only {len(witness_bytes)} bytes")

    if len(witness_bytes) - offset > 0:
        remaining = witness_bytes[offset:]
        print(f"\n⚠️  Remaining bytes ({len(remaining)}): {remaining.hex().upper()}")

def main():
    print("="*80)
    print("DEEP WITNESS ANALYSIS")
    print("="*80)

    conn = sqlite3.connect(WALLET_DB)
    cursor = conn.cursor()

    cursor.execute("""
        SELECT id, received_height, value, hex(witness), length(witness)
        FROM notes
        WHERE is_spent = 0 AND witness IS NOT NULL
        ORDER BY value DESC
        LIMIT 1
    """)

    note = cursor.fetchone()
    conn.close()

    if not note:
        print("❌ No spendable notes")
        return

    note_id, note_height, value, witness_hex, witness_len = note
    witness_bytes = bytes.fromhex(witness_hex)

    print(f"\nNote ID: {note_id}")
    print(f"Height: {note_height}")
    print(f"Value: {value / 100000000:.8f} ZCL")
    print(f"Witness: {witness_len} bytes")

    analyze_witness_deep(witness_bytes)

if __name__ == "__main__":
    main()
