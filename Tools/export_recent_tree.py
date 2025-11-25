#!/usr/bin/env python3
"""
Export Recent Sapling Commitment Tree

Since we have a bundled tree up to block 2920561, we only need to export
CMUs from 2920562 to current. This will be much faster.

Then we can append these to the bundled tree to get a complete current tree.
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

    # Some commands return plain strings (like getblockhash), others return JSON
    try:
        return json.loads(output)
    except json.JSONDecodeError:
        # Return as plain string if not JSON
        return output

def main():
    print("🌳 Exporting Recent Sapling Outputs")
    print("=" * 70)

    # Start from where bundled tree ends
    START_HEIGHT = 2920562

    # Get current chain height
    info = rpc('getblockchaininfo')
    if not info:
        print("❌ Failed to get blockchain info")
        return 1

    current_height = info['blocks']
    print(f"📊 Current height: {current_height:,}")
    print(f"📊 Starting from: {START_HEIGHT:,}")
    print(f"📊 Blocks to scan: {current_height - START_HEIGHT + 1:,}")
    print()

    # Collect CMUs
    cmus = []

    for height in range(START_HEIGHT, current_height + 1):
        block_hash = rpc('getblockhash', height)
        if not block_hash:
            continue

        block = rpc('getblock', block_hash)
        if not block or 'tx' not in block:
            continue

        # Process each transaction
        for txid in block['tx']:
            tx = rpc('getrawtransaction', txid, 1)
            if not tx:
                continue

            # Extract Sapling outputs
            if 'vShieldedOutput' in tx and tx['vShieldedOutput']:
                for output in tx['vShieldedOutput']:
                    if 'cmu' in output:
                        cmu_hex = output['cmu']
                        cmu_bytes = bytes.fromhex(cmu_hex)
                        cmus.append(cmu_bytes)

        if height % 10 == 0:
            print(f"📝 Block {height:,} - {len(cmus):,} CMUs collected", end='\r')

    print()
    print(f"\n✅ Scan complete!")
    print(f"📊 Total new CMUs: {len(cmus):,}")

    # Write to file
    output_file = Path(__file__).parent / 'recent_cmus.bin'

    with open(output_file, 'wb') as f:
        # Write count
        f.write(struct.pack('<Q', len(cmus)))
        # Write CMUs
        for cmu in cmus:
            f.write(cmu)

    print(f"✅ Exported to: {output_file}")
    print(f"💾 Size: {output_file.stat().st_size / 1024:.1f} KB")

    # Now combine with bundled tree
    print("\n🔄 Combining with bundled tree...")

    bundled_file = Path(__file__).parent.parent / 'Resources' / 'commitment_tree.bin'
    if not bundled_file.exists():
        print(f"⚠️  Bundled tree not found at {bundled_file}")
        return 0

    # Read bundled tree
    with open(bundled_file, 'rb') as f:
        bundled_count = struct.unpack('<Q', f.read(8))[0]
        bundled_cmus = []
        for _ in range(bundled_count):
            bundled_cmus.append(f.read(32))

    print(f"📦 Bundled tree: {bundled_count:,} CMUs")
    print(f"📦 Recent CMUs: {len(cmus):,}")

    # Combine
    total_cmus = bundled_cmus + cmus
    print(f"📦 Total: {len(total_cmus):,} CMUs")

    # Write complete tree
    complete_file = Path(__file__).parent.parent / 'Resources' / 'commitment_tree_complete.bin'

    with open(complete_file, 'wb') as f:
        f.write(struct.pack('<Q', len(total_cmus)))
        for cmu in total_cmus:
            f.write(cmu)

    print(f"\n✅ Complete tree created: {complete_file}")
    print(f"💾 Size: {complete_file.stat().st_size / 1024 / 1024:.1f} MB")

    return 0

if __name__ == '__main__':
    sys.exit(main())
