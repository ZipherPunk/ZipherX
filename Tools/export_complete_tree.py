#!/usr/bin/env python3
"""
Export Complete Sapling Commitment Tree from zcashd

This script scans all blocks from Sapling activation to current height,
extracts ALL Sapling outputs (not just ours), and builds a complete
commitment tree that matches zcashd's internal tree state.

Output: commitment_tree_complete.bin
Format: [count: UInt64][cmu1: 32 bytes][cmu2: 32 bytes]...
"""

import subprocess
import json
import struct
import sys
from pathlib import Path

# Zclassic Sapling activation height
SAPLING_ACTIVATION = 476969

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

def get_block_hash(height):
    """Get block hash at height"""
    return rpc('getblockhash', height)

def get_block(block_hash):
    """Get block data"""
    return rpc('getblock', block_hash)

def get_raw_transaction(txid):
    """Get raw transaction"""
    return rpc('getrawtransaction', txid, 1)

def extract_sapling_outputs(height):
    """Extract all Sapling CMUs from a block"""
    block_hash = get_block_hash(height)
    if not block_hash:
        return []

    block = get_block(block_hash)
    if not block or 'tx' not in block:
        return []

    cmus = []
    for txid in block['tx']:
        tx = get_raw_transaction(txid)
        if not tx:
            continue

        # Extract Sapling outputs
        if 'vShieldedOutput' in tx and tx['vShieldedOutput']:
            for output in tx['vShieldedOutput']:
                if 'cmu' in output:
                    # CMU is hex string, convert to bytes
                    cmu_hex = output['cmu']
                    cmu_bytes = bytes.fromhex(cmu_hex)
                    cmus.append(cmu_bytes)

    return cmus

def main():
    print("🌳 Exporting Complete Sapling Commitment Tree from zcashd")
    print("=" * 70)

    # Get current chain height
    info = rpc('getblockchaininfo')
    if not info:
        print("❌ Failed to get blockchain info")
        return 1

    current_height = info['blocks']
    print(f"📊 Chain height: {current_height:,}")
    print(f"📊 Sapling activation: {SAPLING_ACTIVATION:,}")
    print(f"📊 Blocks to scan: {current_height - SAPLING_ACTIVATION + 1:,}")
    print()

    # Collect all CMUs
    all_cmus = []
    total_blocks = current_height - SAPLING_ACTIVATION + 1

    for height in range(SAPLING_ACTIVATION, current_height + 1):
        if height % 1000 == 0:
            progress = ((height - SAPLING_ACTIVATION) / total_blocks) * 100
            print(f"📝 Progress: {progress:.1f}% - Block {height:,} - {len(all_cmus):,} CMUs collected", end='\r')

        cmus = extract_sapling_outputs(height)
        all_cmus.extend(cmus)

    print()
    print(f"\n✅ Scan complete!")
    print(f"📊 Total CMUs collected: {len(all_cmus):,}")
    print(f"📊 Average outputs per block: {len(all_cmus) / total_blocks:.2f}")

    # Write to file
    output_file = Path(__file__).parent.parent / 'Resources' / 'commitment_tree_complete.bin'
    output_file.parent.mkdir(parents=True, exist_ok=True)

    print(f"\n💾 Writing to: {output_file}")

    with open(output_file, 'wb') as f:
        # Write count (UInt64 little-endian)
        f.write(struct.pack('<Q', len(all_cmus)))

        # Write all CMUs
        for cmu in all_cmus:
            f.write(cmu)

    file_size_mb = output_file.stat().st_size / 1024 / 1024
    print(f"✅ Complete tree exported: {file_size_mb:.1f} MB")
    print(f"📦 File: {output_file}")

    return 0

if __name__ == '__main__':
    sys.exit(main())
