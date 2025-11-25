#!/usr/bin/env python3
"""
Compare Trees

Compares CMUs from two different tree export files to identify differences.
Useful for debugging why trees don't match.
"""

import struct
import sys
from pathlib import Path

def load_tree(filepath):
    """Load CMUs from binary tree file"""
    with open(filepath, 'rb') as f:
        count = struct.unpack('<Q', f.read(8))[0]
        cmus = []
        for _ in range(count):
            cmu = f.read(32)
            if len(cmu) != 32:
                break
            cmus.append(cmu)
        return cmus

def main():
    if len(sys.argv) < 3:
        print("Usage: compare_trees.py <tree1.bin> <tree2.bin>")
        print("Example: compare_trees.py old_tree.bin new_tree.bin")
        return 1

    tree1_path = Path(sys.argv[1])
    tree2_path = Path(sys.argv[2])

    if not tree1_path.exists():
        print(f"❌ File not found: {tree1_path}")
        return 1

    if not tree2_path.exists():
        print(f"❌ File not found: {tree2_path}")
        return 1

    print("🔍 Comparing Trees")
    print("=" * 70)

    # Load both trees
    print(f"📦 Loading {tree1_path.name}...")
    cmus1 = load_tree(tree1_path)
    print(f"   Loaded {len(cmus1):,} CMUs")

    print(f"📦 Loading {tree2_path.name}...")
    cmus2 = load_tree(tree2_path)
    print(f"   Loaded {len(cmus2):,} CMUs")

    print()

    # Compare counts
    if len(cmus1) == len(cmus2):
        print(f"✅ Both trees have same count: {len(cmus1):,} CMUs")
    else:
        print(f"❌ Different counts:")
        print(f"   Tree 1: {len(cmus1):,} CMUs")
        print(f"   Tree 2: {len(cmus2):,} CMUs")
        print(f"   Difference: {abs(len(cmus1) - len(cmus2)):,} CMUs")

    print()

    # Find first difference
    min_len = min(len(cmus1), len(cmus2))
    first_diff = None

    for i in range(min_len):
        if cmus1[i] != cmus2[i]:
            first_diff = i
            break

    if first_diff is not None:
        print(f"❌ First difference at index {first_diff:,}:")
        print(f"   Tree 1: {cmus1[first_diff].hex()}")
        print(f"   Tree 2: {cmus2[first_diff].hex()}")
    else:
        if len(cmus1) == len(cmus2):
            print("✅ Trees are IDENTICAL (all CMUs match)")
        else:
            print(f"✅ First {min_len:,} CMUs match")
            if len(cmus1) > len(cmus2):
                print(f"📊 Tree 1 has {len(cmus1) - len(cmus2):,} additional CMUs")
            else:
                print(f"📊 Tree 2 has {len(cmus2) - len(cmus1):,} additional CMUs")

    print()

    # Sample comparison (first 5 and last 5)
    print("📋 Sample comparison (first 5 CMUs):")
    for i in range(min(5, min_len)):
        match = "✅" if cmus1[i] == cmus2[i] else "❌"
        print(f"   [{i}] {match}")
        if cmus1[i] != cmus2[i]:
            print(f"       Tree 1: {cmus1[i].hex()}")
            print(f"       Tree 2: {cmus2[i].hex()}")

    print()
    print("📋 Sample comparison (last 5 CMUs):")
    for i in range(max(0, min_len - 5), min_len):
        match = "✅" if cmus1[i] == cmus2[i] else "❌"
        print(f"   [{i}] {match}")
        if cmus1[i] != cmus2[i]:
            print(f"       Tree 1: {cmus1[i].hex()}")
            print(f"       Tree 2: {cmus2[i].hex()}")

    return 0

if __name__ == '__main__':
    sys.exit(main())
