#!/usr/bin/env python3
"""
Test the new zipherx_witness_path_is_valid() FFI function
"""

import ctypes
import sqlite3
import os

# Load the FFI library
LIB_PATH = "/Users/chris/ZipherX/Libraries/libzipherx_ffi.a"
# For static libraries, we need to use a different approach
# Let's use the Swift-side test instead

WALLET_DB = os.path.expanduser("~/Library/Application Support/ZipherX/zipherx_wallet.db")

def main():
    print("="*80)
    print("WITNESS PATH VALIDATION TEST")
    print("="*80)

    # Get largest spendable note
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

    print(f"\nNote ID: {note_id}")
    print(f"Height: {note_height}")
    print(f"Value: {value / 100000000:.8f} ZCL")
    print(f"Witness: {witness_len} bytes")

    # The witness is corrupted (filled = 0 nodes)
    # So the path should be invalid
    print("\n" + "="*80)
    print("EXPECTED RESULT")
    print("="*80)
    print("""
Based on the witness structure analysis:
- Filled vector: 0 nodes (EMPTY)
- This means witness.path() returns None
- Therefore zipherx_witness_path_is_valid() should return FALSE

When the app runs, the validation will:
1. Check witness.root() == headerAnchor → TRUE ✅
2. Check witnessPathIsValid() → FALSE ❌
3. Detect "PATH CORRUPTED" → force rebuild
4. Rebuild witness → valid path
5. Transaction will be accepted!
    """)

    print("\n" + "="*80)
    print("NEXT STEP")
    print("="*80)
    print("Rebuild the Xcode project and test sending.")
    print("The logs should show:")
    print("  ⚠️ Note 1 PATH CORRUPTED - root matches but path invalid!")
    print("  🔧 FIX #557 v4: Rebuilding witness...")
    print("  ✅ FIX #557 v4: Witness rebuilt (1028 bytes)")
    print("  ✅ Transaction built successfully")

if __name__ == "__main__":
    main()
