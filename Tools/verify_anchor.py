#!/usr/bin/env python3
"""
Verify Anchor at Specific Height

This tool checks what anchor (tree root) zcashd has at a specific block height,
and helps us verify if our computed anchor matches.
"""

import subprocess
import json
import sys

def rpc(method, *params):
    """Call zclassic-cli RPC"""
    cmd = ['zclassic-cli', method] + list(map(str, params))
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        return None

    output = result.stdout.strip()
    if not output:
        return None

    try:
        return json.loads(output)
    except json.JSONDecodeError:
        return output

def main():
    if len(sys.argv) < 2:
        print("Usage: verify_anchor.py <block_height>")
        print("Example: verify_anchor.py 2921565")
        return 1

    height = int(sys.argv[1])

    print(f"🔍 Checking Sapling anchor at block {height:,}")
    print("=" * 70)

    # Get block hash
    block_hash = rpc('getblockhash', height)
    if not block_hash:
        print("❌ Failed to get block hash")
        return 1

    print(f"📦 Block hash: {block_hash}")

    # Get block
    block = rpc('getblock', block_hash)
    if not block:
        print("❌ Failed to get block")
        return 1

    # Get finalsaplingroot
    sapling_root = block.get('finalsaplingroot')
    if not sapling_root:
        print("❌ Block doesn't have finalsaplingroot")
        return 1

    print(f"🌳 zcashd's Sapling root at height {height:,}:")
    print(f"   {sapling_root}")
    print()

    # Count CMUs up to this block
    print(f"💡 To verify your tree:")
    print(f"   1. Build tree from CMUs up to block {height:,}")
    print(f"   2. Compute tree root")
    print(f"   3. Expected root: {sapling_root}")
    print()

    # Show block info
    print(f"📊 Block info:")
    print(f"   Time: {block.get('time', 'N/A')}")
    print(f"   Height: {block.get('height', 'N/A')}")
    print(f"   Confirmations: {block.get('confirmations', 'N/A')}")
    print(f"   Transactions: {len(block.get('tx', []))}")

    return 0

if __name__ == '__main__':
    sys.exit(main())
