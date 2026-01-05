#!/usr/bin/env python3
"""
FIX #546: Anchor Verification Script

This script tests that witness anchors match blockchain headers at their respective heights.
It verifies the fix for the anchor mismatch bug where all witnesses had the same final anchor.
"""

import sqlite3
import sys
from typing import List, Tuple

# Database paths
WALLET_DB = "/Users/chris/Library/Application Support/ZipherX/zipherx_wallet.db"
HEADERS_DB = "/Users/chris/Library/Application Support/ZipherX/zipherx_headers.db"

def get_unspent_notes_with_anchors() -> List[Tuple[int, int, str]]:
    """Get unspent notes with their anchors from the wallet database."""
    conn = sqlite3.connect(WALLET_DB)
    cursor = conn.cursor()

    query = """
    SELECT id, received_height, hex(anchor)
    FROM notes
    WHERE is_spent = 0 AND anchor IS NOT NULL
    ORDER BY received_height DESC
    """

    cursor.execute(query)
    results = cursor.fetchall()
    conn.close()

    return [(row[0], row[1], row[2]) for row in results]

def get_sapling_roots(heights: List[int]) -> dict:
    """Get sapling roots for specific heights from headers database."""
    conn = sqlite3.connect(HEADERS_DB)
    cursor = conn.cursor()

    placeholders = ','.join('?' * len(heights))
    query = f"SELECT height, hex(sapling_root) FROM headers WHERE height IN ({placeholders})"

    cursor.execute(query, heights)
    results = cursor.fetchall()
    conn.close()

    return {row[0]: row[1] for row in results}

def normalize_anchor(anchor: str) -> str:
    """Normalize anchor to consistent format (uppercase, remove leading 0x if present)."""
    if anchor.startswith('0x'):
        anchor = anchor[2:]
    return anchor.upper()

def verify_anchors() -> Tuple[int, int, List[dict]]:
    """Verify that witness anchors match blockchain headers.

    Returns:
        (total_notes, matching_notes, mismatches)
    """
    notes = get_unspent_notes_with_anchors()

    if not notes:
        print("❌ No unspent notes with anchors found!")
        return 0, 0, []

    print(f"📝 Found {len(notes)} unspent notes with anchors")

    # Get sapling roots from headers database
    heights = [note[1] for note in notes]
    sapling_roots = get_sapling_roots(heights)

    mismatches = []
    matching = 0

    for note_id, height, witness_anchor in notes:
        # Get sapling root from headers database
        header_root = sapling_roots.get(height)

        if not header_root:
            print(f"⚠️  Height {height}: No header found")
            continue

        # Normalize both to uppercase for comparison
        witness_anchor_norm = normalize_anchor(witness_anchor)
        header_root_norm = normalize_anchor(header_root)

        # Compare
        if witness_anchor_norm == header_root_norm:
            matching += 1
            print(f"✅ Height {height}: MATCH ({witness_anchor_norm[:16]}...)")
        else:
            mismatches.append({
                'note_id': note_id,
                'height': height,
                'witness_anchor': witness_anchor_norm,
                'header_root': header_root_norm
            })
            print(f"❌ Height {height}: MISMATCH!")
            print(f"   Witness: {witness_anchor_norm[:16]}...")
            print(f"   Header:  {header_root_norm[:16]}...")

    return len(notes), matching, mismatches

def analyze_mismatches(mismatches: List[dict]) -> None:
    """Analyze the pattern of mismatches to identify the root cause."""
    if not mismatches:
        return

    print("\n" + "="*70)
    print("🔍 MISMATCH ANALYSIS")
    print("="*70)

    # Check if all witnesses have the same anchor (the bug!)
    anchors = [m['witness_anchor'] for m in mismatches]
    unique_anchors = set(anchors)

    if len(unique_anchors) == 1:
        print(f"\n❌ BUG CONFIRMED: All {len(mismatches)} witnesses have the SAME anchor!")
        print(f"   Anchor: {anchors[0][:16]}...")
        print("\n   This means witnesses are being created with the FINAL tree root")
        print("   instead of their position-specific tree root.")

        # Find which height this anchor belongs to
        print("\n   Finding which height this anchor actually belongs to...")

        # The mismatching entries include the correct header root, so we can find
        # which height's witness anchor matches its header
        conn = sqlite3.connect(HEADERS_DB)
        cursor = conn.cursor()

        # Get a sample of the anchor (full 64 hex chars)
        sample_anchor = anchors[0]
        cursor.execute(
            "SELECT height FROM headers WHERE hex(sapling_root) = ? LIMIT 1",
            [sample_anchor]
        )
        result = cursor.fetchone()
        conn.close()

        if result:
            actual_height = result[0]
            print(f"   → This anchor belongs to height {actual_height}")
            print(f"   → But it's being used for ALL witness heights!")
    else:
        print(f"\n⚠️  Found {len(unique_anchors)} different anchors (not all the same)")
        print("   This might be a different issue...")

def main():
    print("="*70)
    print("FIX #546: Anchor Verification Script")
    print("="*70)
    print()

    total, matching, mismatches = verify_anchors()

    print("\n" + "="*70)
    print("SUMMARY")
    print("="*70)
    print(f"Total notes: {total}")
    print(f"Matching: {matching} ✅")
    print(f"Mismatching: {len(mismatches)} ❌")

    if mismatches:
        analyze_mismatches(mismatches)
        sys.exit(1)
    else:
        print("\n🎉 SUCCESS! All anchors match their blockchain headers!")
        sys.exit(0)

if __name__ == "__main__":
    main()
