#!/usr/bin/env python3
"""
Zcash Sapling Anchor Verification Script (FIXED)

CRITICAL: In Zcash Sapling, ALL witnesses should have the SAME anchor - the CURRENT tree root!
A witness is a Merkle path from the note's CMU position to the CURRENT tree root.

When you build a transaction, you need the witness to point to the current tree state,
so the transaction can be verified against the current blockchain.

This script verifies that all witnesses have been updated to the current tree root.
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

    CRITICAL: In Zcash Sapling, ALL witnesses should have the SAME anchor - the CURRENT tree root!
    A witness is a Merkle path from note position to CURRENT tree root, NOT historical root.

    Returns:
        (total_notes, matching_notes, mismatches)
    """
    notes = get_unspent_notes_with_anchors()

    if not notes:
        print("❌ No unspent notes with anchors found!")
        return 0, 0, []

    print(f"📝 Found {len(notes)} unspent notes with anchors")

    # Get CURRENT (latest) sapling root from headers database
    conn = sqlite3.connect(HEADERS_DB)
    cursor = conn.cursor()
    cursor.execute("SELECT height, hex(sapling_root) FROM headers ORDER BY height DESC LIMIT 1")
    result = cursor.fetchone()
    conn.close()

    if not result:
        print("❌ No headers found in database!")
        return 0, 0, []

    current_height, current_root = result
    print(f"📊 Current chain height: {current_height}")
    print(f"📊 Current tree root: {current_root[:16]}...")

    # All witnesses should have the same anchor - the CURRENT tree root
    current_root_norm = normalize_anchor(current_root)

    mismatches = []
    matching = 0

    for note_id, height, witness_anchor in notes:
        # Normalize witness anchor to uppercase for comparison
        witness_anchor_norm = normalize_anchor(witness_anchor)

        # Compare against CURRENT tree root (not note's height!)
        if witness_anchor_norm == current_root_norm:
            matching += 1
            if matching <= 5:  # Only print first 5 to avoid spam
                print(f"✅ Note {note_id} (height {height}): MATCH ({witness_anchor_norm[:16]}...)")
        else:
            mismatches.append({
                'note_id': note_id,
                'height': height,
                'witness_anchor': witness_anchor_norm,
                'current_root': current_root_norm,
                'current_height': current_height
            })
            print(f"❌ Note {note_id} (height {height}): MISMATCH!")
            print(f"   Witness anchor: {witness_anchor_norm[:16]}...")
            print(f"   Current root:  {current_root_norm[:16]}... (height {current_height})")

    if matching > 5:
        print(f"   ... and {matching - 5} more matches")

    return len(notes), matching, mismatches

def analyze_mismatches(mismatches: List[dict]) -> None:
    """Analyze the pattern of mismatches to identify the root cause."""
    if not mismatches:
        return

    print("\n" + "="*70)
    print("🔍 MISMATCH ANALYSIS")
    print("="*70)

    # Group mismatched notes by their witness anchor
    anchors = {}
    for m in mismatches:
        anchor = m['witness_anchor']
        if anchor not in anchors:
            anchors[anchor] = []
        anchors[anchor].append(m)

    print(f"\n❌ Found {len(mismatches)} witnesses with stale anchors")
    print(f"   {len(anchors)} different stale anchor(s) detected")

    for anchor, notes in anchors.items():
        print(f"\n   Stale anchor: {anchor[:16]}...")
        print(f"   Affects {len(notes)} note(s)")
        # Show a few sample heights
        sample_heights = [n['height'] for n in notes[:3]]
        print(f"   Sample heights: {sample_heights}...")
        if len(notes) > 3:
            print(f"   ... and {len(notes) - 3} more")

    # Get current root info from first mismatch
    current_root = mismatches[0]['current_root']
    current_height = mismatches[0]['current_height']
    print(f"\n   Expected anchor (current root at height {current_height}):")
    print(f"   {current_root[:16]}...")

def main():
    print("="*70)
    print("Zcash Sapling Anchor Verification Script (FIXED)")
    print("="*70)
    print()
    print("⚠️  IMPORTANT: In Zcash Sapling, ALL witnesses should have the SAME anchor!")
    print("   The anchor is the CURRENT tree root, not the historical root at note height.")
    print()

    total, matching, mismatches = verify_anchors()

    print("\n" + "="*70)
    print("SUMMARY")
    print("="*70)
    print(f"Total notes: {total}")
    print(f"Matching current anchor: {matching} ✅")
    print(f"Mismatching (stale): {len(mismatches)} ❌")

    if mismatches:
        analyze_mismatches(mismatches)
        sys.exit(1)
    else:
        print("\n🎉 SUCCESS! All witnesses have the correct current anchor!")
        sys.exit(0)

if __name__ == "__main__":
    main()
