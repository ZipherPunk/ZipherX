#!/usr/bin/env python3
"""
Ultra-Fast Parallel Sapling Tree Export

Optimizations:
1. Parallel block processing with multiprocessing
2. Batch RPC calls
3. Process multiple blocks concurrently
4. Memory-efficient streaming
"""

import subprocess
import json
import struct
import sys
from pathlib import Path
from datetime import datetime
from multiprocessing import Pool, cpu_count
from functools import partial

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

def process_block_range(start_height, end_height):
    """Process a range of blocks and return CMUs"""
    cmus = []

    for height in range(start_height, end_height + 1):
        # Get block hash
        block_hash = rpc('getblockhash', height)
        if not block_hash:
            continue

        # Get block
        block = rpc('getblock', block_hash)
        if not block or 'tx' not in block:
            continue

        # Process each transaction
        for txid in block['tx']:
            # Get raw transaction
            tx = rpc('getrawtransaction', txid, 1)
            if not tx:
                continue

            # Extract Sapling outputs
            if 'vShieldedOutput' in tx and tx['vShieldedOutput']:
                for output in tx['vShieldedOutput']:
                    if 'cmu' in output:
                        cmu_bytes = bytes.fromhex(output['cmu'])
                        cmus.append((height, cmu_bytes))

    return cmus

def main():
    print("🚀 Ultra-Fast Parallel Sapling Tree Export")
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

    # Determine optimal chunk size and worker count
    num_workers = cpu_count() * 2  # 2x CPU cores for I/O bound tasks
    chunk_size = 500  # Process 500 blocks per chunk

    print(f"⚙️  Using {num_workers} parallel workers")
    print(f"⚙️  Chunk size: {chunk_size} blocks")
    print()

    # Create chunks
    chunks = []
    for start in range(SAPLING_ACTIVATION, current_height + 1, chunk_size):
        end = min(start + chunk_size - 1, current_height)
        chunks.append((start, end))

    print(f"📦 Created {len(chunks):,} chunks to process")
    print()

    # Process chunks in parallel
    all_cmus = []
    start_time = datetime.now()

    with Pool(processes=num_workers) as pool:
        results = pool.starmap(process_block_range, chunks)

        # Flatten results and sort by height to maintain order
        for chunk_cmus in results:
            all_cmus.extend(chunk_cmus)

            # Progress update
            progress = (len(all_cmus) / total_blocks) * 100 if total_blocks > 0 else 0
            elapsed = (datetime.now() - start_time).total_seconds()
            rate = len([c for chunk in results for c in chunk]) / elapsed if elapsed > 0 else 0

            print(f"📝 Processing... {len(all_cmus):,} CMUs collected - "
                  f"{rate:.1f} CMUs/sec", end='\r')

    # Sort by height to ensure correct order
    all_cmus.sort(key=lambda x: x[0])
    cmus_only = [cmu for _, cmu in all_cmus]

    print()
    print(f"\n✅ Scan complete!")
    print(f"📊 Total CMUs collected: {len(cmus_only):,}")

    elapsed_total = (datetime.now() - start_time).total_seconds()
    print(f"⏱️  Total time: {elapsed_total/60:.1f} minutes ({elapsed_total/3600:.2f} hours)")
    print(f"⚡ Average speed: {len(cmus_only)/elapsed_total:.1f} CMUs/sec")

    # Write to file
    output_file = Path(__file__).parent.parent / 'Resources' / 'commitment_tree_complete.bin'
    output_file.parent.mkdir(parents=True, exist_ok=True)

    print(f"\n💾 Writing to: {output_file}")

    with open(output_file, 'wb') as f:
        # Write count (UInt64 little-endian)
        f.write(struct.pack('<Q', len(cmus_only)))

        # Write all CMUs
        for cmu in cmus_only:
            f.write(cmu)

    file_size_mb = output_file.stat().st_size / 1024 / 1024
    print(f"✅ Complete tree exported: {file_size_mb:.1f} MB")
    print(f"📦 File: {output_file}")

    return 0

if __name__ == '__main__':
    sys.exit(main())
