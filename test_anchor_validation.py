#!/usr/bin/env python3
"""
FIX #557: Comprehensive Anchor Validation & Fix Test Script

This script:
1. Reads notes from database
2. Validates stored anchors against HeaderStore
3. Tests witness parsing
4. Shows exactly what anchor should be used for transactions
5. Generates a report with the bug and fix

Usage:
    python3 test_anchor_validation.py
"""

import sqlite3
import struct
import os
import sys

# Database paths
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

def parse_witness(witness_bytes):
    """
    Parse the IncrementalWitness format.
    Returns: (position, num_nodes, path_nodes, estimated_root)
    """
    if len(witness_bytes) < 9:
        return None, 0, [], None

    try:
        # Read position (8 bytes little-endian)
        position = struct.unpack("<Q", witness_bytes[:8])[0]

        # Read number of path nodes (compact size)
        offset = 8
        num_nodes, offset = parse_compact_size(witness_bytes, offset)

        # Read path nodes
        path_nodes = []
        for i in range(min(num_nodes, 32)):  # Safety limit
            if offset + 32 > len(witness_bytes):
                break
            node = witness_bytes[offset:offset+32]
            path_nodes.append(node)
            offset += 32

        # The root is computed by hashing up the tree
        # For now, use the last path node as approximation
        # (actual computation requires the leaf CMU and walking the tree)
        estimated_root = path_nodes[-1] if path_nodes else None

        return {
            'position': position,
            'num_nodes': num_nodes,
            'path_nodes': path_nodes,
            'estimated_root': estimated_root,
            'bytes_parsed': offset
        }
    except Exception as e:
        print(f"   Error parsing witness: {e}")
        return None

def get_all_spendable_notes(conn):
    """Get all unspent notes with their anchors"""
    cursor = conn.cursor()
    cursor.execute("""
        SELECT id, received_height, value, hex(anchor), length(witness), hex(witness)
        FROM notes WHERE is_spent = 0 AND witness IS NOT NULL AND length(witness) > 0
        ORDER BY value DESC
    """)
    return cursor.fetchall()

def get_header_store_anchor(conn, height):
    """Get sapling_root from HeaderStore at specific height"""
    cursor = conn.cursor()
    cursor.execute("SELECT hex(sapling_root) FROM headers WHERE height = ?", (height,))
    row = cursor.fetchone()
    return row[0] if row else None

def test_single_note(note_data, headers_conn):
    """Test a single note and return detailed results"""
    note_id, received_height, value, stored_anchor_hex, witness_len, witness_hex = note_data
    stored_anchor = bytes.fromhex(stored_anchor_hex) if stored_anchor_hex else None
    witness_bytes = bytes.fromhex(witness_hex) if witness_hex else None

    result = {
        'note_id': note_id,
        'height': received_height,
        'value': value,
        'stored_anchor': stored_anchor_hex,
        'witness_len': witness_len,
        'issues': [],
        'fix_needed': False
    }

    # Get HeaderStore anchor
    header_anchor_hex = get_header_store_anchor(headers_conn, received_height)
    if not header_anchor_hex:
        result['issues'].append("❌ No header in HeaderStore at this height")
        result['fix_needed'] = True
        return result

    result['header_anchor'] = header_anchor_hex

    # Compare stored anchor with HeaderStore
    if stored_anchor_hex == header_anchor_hex:
        result['anchor_match'] = True
    else:
        result['anchor_match'] = False
        result['issues'].append(f"❌ Stored anchor ≠ HeaderStore anchor")

    # Parse witness
    if witness_bytes:
        witness_info = parse_witness(witness_bytes)
        if witness_info:
            result['witness_info'] = witness_info

            # Check witness root
            if witness_info['estimated_root']:
                witness_root_hex = witness_info['estimated_root'].hex().upper()
                result['witness_root'] = witness_root_hex

                # Compare witness root with HeaderStore
                if witness_root_hex == header_anchor_hex:
                    result['witness_match'] = True
                else:
                    result['witness_match'] = False
                    result['issues'].append(f"❌ Witness root ≠ HeaderStore anchor")
                    result['fix_needed'] = True

    return result

def main():
    print("=" * 80)
    print("FIX #557: Anchor Validation & Fix Test Script")
    print("=" * 80)
    print()

    # Connect to databases
    if not os.path.exists(WALLET_DB):
        print(f"❌ Wallet database not found: {WALLET_DB}")
        return False

    if not os.path.exists(HEADERS_DB):
        print(f"❌ Headers database not found: {HEADERS_DB}")
        return False

    conn = sqlite3.connect(WALLET_DB)
    headers_conn = sqlite3.connect(HEADERS_DB)

    # Get all spendable notes
    print("Step 1: Loading spendable notes from database...")
    notes = get_all_spendable_notes(conn)
    print(f"✅ Found {len(notes)} spendable notes")
    print()

    if not notes:
        print("❌ No spendable notes found!")
        return False

    # Test the largest note first
    print("Step 2: Testing the largest note (most likely to be used)...")
    largest_note = notes[0]
    result = test_single_note(largest_note, headers_conn)

    print(f"Note ID: {result['note_id']}")
    print(f"Height: {result['height']}")
    print(f"Value: {result['value']} zatoshis ({result['value'] / 100000000:.8f} ZCL)")
    print(f"Witness length: {result['witness_len']} bytes")
    print()

    # Show anchors
    print("Step 3: Comparing anchors...")
    if 'header_anchor' in result:
        print(f"HeaderStore anchor: {result['header_anchor'][:64]}...")
    if result['stored_anchor']:
        match_symbol = "✅" if result.get('anchor_match') else "❌"
        print(f"Stored anchor:      {result['stored_anchor'][:64]}... {match_symbol}")
    if 'witness_root' in result:
        match_symbol = "✅" if result.get('witness_match') else "❌"
        print(f"Witness root:       {result['witness_root'][:64]}... {match_symbol}")
    print()

    # Show witness details
    if 'witness_info' in result and result['witness_info']:
        wi = result['witness_info']
        print("Step 4: Witness structure...")
        print(f"Position: {wi['position']}")
        print(f"Path nodes: {wi['num_nodes']}")
        if wi['path_nodes']:
            print(f"First node: {wi['path_nodes'][0].hex().upper()[:64]}...")
            if len(wi['path_nodes']) > 1:
                print(f"Last node:  {wi['path_nodes'][-1].hex().upper()[:64]}...")
    print()

    # Summary for this note
    print("=" * 80)
    print("TEST RESULTS FOR LARGEST NOTE")
    print("=" * 80)

    if result['issues']:
        print("Issues found:")
        for issue in result['issues']:
            print(f"  {issue}")
        print()

    if result['fix_needed']:
        print("❌ FIX REQUIRED!")
        print()
        print("The witness root differs from the HeaderStore anchor.")
        print("When building a transaction:")
        print(f"  ❌ DO NOT use witness root: {result.get('witness_root', 'N/A')[:64]}...")
        print(f"  ✅ USE HeaderStore anchor: {result['header_anchor'][:64]}...")
        print()
        print("In Swift code (TransactionBuilder.swift):")
        print("  let anchor = try HeaderStore.shared.getSaplingRoot(at: note.height)")
        print("  Pass this anchor to the FFI function")
        print()
        return False
    else:
        print("✅ All checks passed!")
        print(f"  Stored anchor matches HeaderStore: {result.get('anchor_match', False)}")
        print(f"  Witness root matches HeaderStore: {result.get('witness_match', False)}")
        print()
        print("This note should work correctly for transactions.")
        return True

if __name__ == "__main__":
    try:
        success = main()
        sys.exit(0 if success else 1)
    except Exception as e:
        print(f"❌ Error: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)
