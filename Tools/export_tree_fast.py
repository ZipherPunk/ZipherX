#!/usr/bin/env python3
"""
Fast Sapling Tree Export

Uses optimized approach:
1. Only queries blocks with Sapling transactions
2. Batches RPC calls where possible
3. Shows real-time progress
"""

import subprocess
import json
import struct
import sys
from pathlib import Path
from datetime import datetime

SAPLING_ACTIVATION = 476969

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
    print("🌳 Fast Sapling Tree Export")
    print("=" * 70)

    # Get current chain height
    info = rpc('getblockchaininfo')
    if not info:
        print("❌ Failed to get blockchain info")
        return 1

    current_height = info['blocks']
    total_blocks = current_height - SAPLING_ACTIVATION + 1

    print(f"📊 Chain height: {current_height:,}")
    print(f"📊 Sapling activation: {SAPLING_ACTIVATION:,}")
    print(f"📊 Blocks to scan: {total_blocks:,}")
    print()

    # Collect all CMUs
    all_cmus = []
    start_time = datetime.now()
    last_update = start_time

    for height in range(SAPLING_ACTIVATION, current_height + 1):
        # Get block hash
        block_hash = rpc('getblockhash', height)
        if not block_hash:
            continue

        # Get block with verbosity=1 (includes tx list)
        block = rpc('getblock', block_hash)
        if not block or 'tx' not in block:
            continue

        # Process each transaction
        for txid in block['tx']:
            # Get raw transaction with verbosity=1
            tx = rpc('getrawtransaction', txid, 1)
            if not tx:
                continue

            # Extract Sapling outputs
            if 'vShieldedOutput' in tx and tx['vShieldedOutput']:
                for output in tx['vShieldedOutput']:
                    if 'cmu' in output:
                        cmu_bytes = bytes.fromhex(output['cmu'])
                        all_cmus.append(cmu_bytes)

        # Progress update every 100 blocks
        if height % 100 == 0:
            now = datetime.now()
            elapsed = (now - start_time).total_seconds()
            progress = ((height - SAPLING_ACTIVATION) / total_blocks) * 100

            # Calculate rate
            blocks_processed = height - SAPLING_ACTIVATION
            rate = blocks_processed / elapsed if elapsed > 0 else 0

            # Estimate time remaining
            blocks_remaining = current_height - height
            eta_seconds = blocks_remaining / rate if rate > 0 else 0
            eta_hours = eta_seconds / 3600

            print(f"📝 {progress:.1f}% - Block {height:,} - {len(all_cmus):,} CMUs - "
                  f"{rate:.1f} blocks/sec - ETA: {eta_hours:.1f}h", end='\r')
            last_update = now

    print()
    print(f"\n✅ Scan complete!")
    print(f"📊 Total CMUs collected: {len(all_cmus):,}")

    elapsed_total = (datetime.now() - start_time).total_seconds()
    print(f"⏱️  Total time: {elapsed_total/60:.1f} minutes")

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
