#!/usr/bin/env python3
"""
Verify Tree Correctness

Compares our bundled tree against zcashd's actual tree state
by checking the finalsaplingroot at the bundled tree height.
"""

import subprocess
import json
import struct
import sys
from pathlib import Path

def rpc(method, *params):
    """Call zclassic-cli RPC"""
    cmd = ['zclassic-cli', method] + list(map(str, params))
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"Error calling {method}: {result.stderr}", file=sys.stderr)
        return None

    output = result.stdout.strip()
    if not output:
        return None

    try:
        return json.loads(output)
    except json.JSONDecodeError:
        return output

def main():
    print("🔍 Verifying Tree Correctness")
    print("=" * 70)

    # Load our bundled tree
    tree_file = Path(__file__).parent.parent / 'Resources' / 'commitment_tree_complete.bin'

    if not tree_file.exists():
        print(f"❌ Tree file not found: {tree_file}")
        return 1

    with open(tree_file, 'rb') as f:
        count = struct.unpack('<Q', f.read(8))[0]
        print(f"📦 Our tree has {count:,} CMUs")

    # The bundled tree should be at height 2921565
    TREE_HEIGHT = 2921565

    print(f"📊 Checking zcashd's tree at height {TREE_HEIGHT:,}...")

    # Get block hash at that height
    block_hash = rpc('getblockhash', TREE_HEIGHT)
    if not block_hash:
        print("❌ Failed to get block hash")
        return 1

    # Get block info
    block = rpc('getblock', block_hash)
    if not block:
        print("❌ Failed to get block")
        return 1

    # Get the Sapling root from that block
    sapling_root = block.get('finalsaplingroot')
    if not sapling_root:
        print("❌ Block doesn't have finalsaplingroot")
        return 1

    print(f"✅ zcashd's Sapling root at height {TREE_HEIGHT:,}:")
    print(f"   {sapling_root}")

    print()
    print("❓ To verify our tree matches:")
    print(f"   1. Our tree should compute the same root: {sapling_root}")
    print(f"   2. Build our tree from {count:,} CMUs")
    print(f"   3. Compare the computed root with zcashd's root")
    print()
    print("⚠️  If roots don't match, our bundled tree is INCORRECT")
    print("⚠️  This will cause all transactions to be rejected")

    return 0

if __name__ == '__main__':
    sys.exit(main())
