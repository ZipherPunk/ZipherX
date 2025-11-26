#!/usr/bin/env python3
"""
Ultra-Fast Sapling Tree Export

Optimizations:
1. Uses getblock verbosity=2 to get full tx data in one call (no getrawtransaction needed)
2. Parallel processing with ThreadPoolExecutor
3. Batch processing of blocks
4. Progress streaming to file (resume support)
"""

import subprocess
import json
import struct
import sys
import os
from pathlib import Path
from datetime import datetime
from concurrent.futures import ThreadPoolExecutor, as_completed
import threading

SAPLING_ACTIVATION = 476969
BATCH_SIZE = 50  # Process blocks in batches
MAX_WORKERS = 8  # Parallel RPC calls

# Thread-safe CMU collection
cmu_lock = threading.Lock()
block_cmus = {}  # height -> [cmus]

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

def process_block(height):
    """Process a single block and return its CMUs"""
    try:
        # Get block hash
        block_hash = rpc('getblockhash', height)
        if not block_hash:
            return height, []

        # Get block with verbosity=2 (includes full tx data!)
        # This avoids separate getrawtransaction calls
        block = rpc('getblock', block_hash, 2)
        if not block or 'tx' not in block:
            return height, []

        cmus = []
        for tx in block['tx']:
            if isinstance(tx, dict) and 'vShieldedOutput' in tx and tx['vShieldedOutput']:
                for output in tx['vShieldedOutput']:
                    if 'cmu' in output:
                        # CRITICAL: cmu from RPC is big-endian (display format)
                        # librustzcash expects little-endian, so we reverse
                        cmu_bytes = bytes.fromhex(output['cmu'])
                        cmu_le = bytes(reversed(cmu_bytes))
                        cmus.append(cmu_le)

        return height, cmus
    except Exception as e:
        print(f"\n⚠️ Error at block {height}: {e}")
        return height, []

def main():
    print("🌳 Ultra-Fast Sapling Tree Export")
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
    print(f"⚡ Using {MAX_WORKERS} parallel workers")
    print()

    # Check for resume file
    output_file = Path(__file__).parent.parent / 'Resources' / 'commitment_tree_complete.bin'
    temp_file = output_file.with_suffix('.tmp')
    progress_file = output_file.with_suffix('.progress')

    start_height = SAPLING_ACTIVATION
    all_cmus = []

    # Resume from previous run if available
    if progress_file.exists() and temp_file.exists():
        try:
            with open(progress_file, 'r') as f:
                data = json.load(f)
                start_height = data['last_height'] + 1

            # Load existing CMUs
            with open(temp_file, 'rb') as f:
                count = struct.unpack('<Q', f.read(8))[0]
                for _ in range(count):
                    all_cmus.append(f.read(32))

            print(f"📂 Resuming from block {start_height:,} ({len(all_cmus):,} CMUs loaded)")
        except Exception as e:
            print(f"⚠️ Could not resume: {e}, starting fresh")
            start_height = SAPLING_ACTIVATION
            all_cmus = []

    start_time = datetime.now()
    processed = 0
    last_save = start_time

    # Process blocks in parallel batches
    heights = list(range(start_height, current_height + 1))

    with ThreadPoolExecutor(max_workers=MAX_WORKERS) as executor:
        # Submit all blocks
        future_to_height = {executor.submit(process_block, h): h for h in heights}

        # Collect results as they complete
        results = {}
        for future in as_completed(future_to_height):
            height, cmus = future.result()
            results[height] = cmus
            processed += 1

            # Progress update
            if processed % 100 == 0 or processed == len(heights):
                elapsed = (datetime.now() - start_time).total_seconds()
                rate = processed / elapsed if elapsed > 0 else 0
                remaining = len(heights) - processed
                eta_seconds = remaining / rate if rate > 0 else 0
                eta_min = eta_seconds / 60

                total_cmus = len(all_cmus) + sum(len(results.get(h, [])) for h in range(start_height, height + 1) if h in results)
                progress = (processed / len(heights)) * 100

                print(f"\r⚡ {progress:.1f}% - {processed:,}/{len(heights):,} blocks - "
                      f"{total_cmus:,} CMUs - {rate:.1f} blk/s - ETA: {eta_min:.1f}m   ", end='', flush=True)

            # Save progress every 5 minutes
            if (datetime.now() - last_save).total_seconds() > 300:
                # Sort and append CMUs in order
                sorted_heights = sorted(results.keys())
                for h in sorted_heights:
                    if h not in block_cmus:
                        block_cmus[h] = results[h]

                # Save to temp file
                save_progress(temp_file, progress_file, all_cmus, block_cmus, max(results.keys()))
                last_save = datetime.now()
                print(f"\n💾 Progress saved at block {max(results.keys()):,}")

    print()

    # Collect all CMUs in order
    print("📝 Collecting CMUs in block order...")
    for height in sorted(results.keys()):
        all_cmus.extend(results[height])

    print(f"\n✅ Scan complete!")
    print(f"📊 Total CMUs collected: {len(all_cmus):,}")

    elapsed_total = (datetime.now() - start_time).total_seconds()
    print(f"⏱️  Total time: {elapsed_total/60:.1f} minutes")
    print(f"⚡ Average speed: {len(heights)/elapsed_total:.1f} blocks/sec")

    # Write final file
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

    # Cleanup temp files
    if temp_file.exists():
        temp_file.unlink()
    if progress_file.exists():
        progress_file.unlink()

    return 0

def save_progress(temp_file, progress_file, all_cmus, block_cmus, last_height):
    """Save progress for resume capability"""
    # Collect CMUs in order
    heights = sorted(block_cmus.keys())
    cmus_to_save = list(all_cmus)
    for h in heights:
        cmus_to_save.extend(block_cmus[h])

    # Write CMUs
    with open(temp_file, 'wb') as f:
        f.write(struct.pack('<Q', len(cmus_to_save)))
        for cmu in cmus_to_save:
            f.write(cmu)

    # Write progress
    with open(progress_file, 'w') as f:
        json.dump({'last_height': last_height}, f)

if __name__ == '__main__':
    sys.exit(main())
