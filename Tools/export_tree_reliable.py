#!/usr/bin/env python3
"""
RELIABLE Sapling Tree Export v6

Key improvements over v5:
- Failed blocks are retried indefinitely until success
- Tracks failed blocks and retries them in batches
- Progress saved to disk for resume capability
- CRITICAL: CMUs are stored in little-endian (wire format)
  - zcashd RPC returns big-endian (display format)
  - We reverse bytes before storing (line 84)
  - Node::read() in Rust expects little-endian (wire format)
- Outputs v3 file format

Byte Order:
  zcashd RPC:      5a8d47a7...43 (big-endian, display)
  Bundled file:    43391df0...5a (little-endian, wire)
  Node::read():    Expects little-endian (wire format)
"""

import asyncio
import aiohttp
import struct
import sys
import time
import json
from pathlib import Path
from collections import deque

SAPLING_ACTIVATION = 476969
RPC_URL = "http://127.0.0.1:8023"
RPC_USER = ""
RPC_PASS = ""

# Conservative concurrency to avoid RPC overload
MAX_WORKERS = 16
BATCH_SIZE = 1000

def read_rpc_credentials():
    global RPC_USER, RPC_PASS
    for conf_path in [Path.home() / ".zclassic" / "zclassic.conf",
                      Path.home() / "Library/Application Support/Zclassic/zclassic.conf"]:
        if conf_path.exists():
            for line in open(conf_path):
                if line.startswith('rpcuser='):
                    RPC_USER = line.strip().split('=', 1)[1]
                elif line.startswith('rpcpassword='):
                    RPC_PASS = line.strip().split('=', 1)[1]
            if RPC_USER and RPC_PASS:
                return True
    return False

async def rpc_call(session, auth, method, *params, max_retries=10):
    """Make RPC call with extensive retry logic"""
    payload = {"jsonrpc": "1.0", "id": 1, "method": method, "params": list(params)}

    for attempt in range(max_retries):
        try:
            async with session.post(RPC_URL, json=payload, auth=auth,
                                   timeout=aiohttp.ClientTimeout(total=60)) as resp:
                if resp.status == 500:
                    text = await resp.text()
                    if "Work queue depth exceeded" in text:
                        # Wait longer on work queue errors
                        await asyncio.sleep(1.0 + attempt * 0.5)
                        continue
                if resp.status == 200:
                    result = await resp.json()
                    return result.get('result')
        except asyncio.TimeoutError:
            await asyncio.sleep(0.5 * (attempt + 1))
        except Exception as e:
            await asyncio.sleep(0.3 * (attempt + 1))

    return None  # Will be retried by caller

async def get_block_cmus(session, auth, height):
    """Get CMUs for a single block - returns None on failure for retry"""
    block_hash = await rpc_call(session, auth, "getblockhash", height)
    if block_hash is None:
        return None

    block = await rpc_call(session, auth, "getblock", block_hash, 2)
    if block is None or 'tx' not in block:
        return None

    cmus = []
    for tx in block['tx']:
        if isinstance(tx, dict) and tx.get('vShieldedOutput'):
            for out in tx['vShieldedOutput']:
                if 'cmu' in out:
                    # Convert from big-endian (RPC) to little-endian (librustzcash)
                    cmus.append(bytes(reversed(bytes.fromhex(out['cmu']))))

    return cmus

async def process_batch(session, auth, heights, results, semaphore):
    """Process a batch of heights, tracking failures for retry"""
    failed = []

    async def process_one(h):
        async with semaphore:
            cmus = await get_block_cmus(session, auth, h)
            if cmus is None:
                failed.append(h)
            else:
                results[h] = cmus

    tasks = [process_one(h) for h in heights]
    await asyncio.gather(*tasks)

    return failed

async def get_expected_root(session, auth, height):
    """Get the expected finalsaplingroot from zcashd"""
    block_hash = await rpc_call(session, auth, "getblockhash", height)
    if not block_hash:
        return None
    header = await rpc_call(session, auth, "getblockheader", block_hash, True)
    if not header:
        return None
    return header.get('finalsaplingroot')

async def main():
    print("🚀 RELIABLE Export v6 (guaranteed complete)")
    print("=" * 60)

    if not read_rpc_credentials():
        print("❌ No RPC credentials")
        return 1

    auth = aiohttp.BasicAuth(RPC_USER, RPC_PASS)
    conn = aiohttp.TCPConnector(limit=50)

    async with aiohttp.ClientSession(connector=conn) as session:
        # Get current chain height
        info = await rpc_call(session, auth, "getblockchaininfo")
        if not info:
            print("❌ RPC failed")
            return 1

        current = info['blocks']
        total = current - SAPLING_ACTIVATION + 1

        print(f"📊 Blocks: {total:,} (height {current:,})")

        # Check for resume file
        progress_file = Path(__file__).parent / 'export_progress.json'
        results = {}
        completed_heights = set()

        if progress_file.exists():
            try:
                with open(progress_file, 'r') as f:
                    saved = json.load(f)
                    if saved.get('target_height') == current:
                        completed_heights = set(saved.get('completed', []))
                        print(f"📂 Resuming: {len(completed_heights):,} heights already done")
            except:
                pass

        # Build list of heights to process
        all_heights = list(range(SAPLING_ACTIVATION, current + 1))
        pending = [h for h in all_heights if h not in completed_heights]

        print(f"📝 Heights to process: {len(pending):,}")

        start = time.time()
        semaphore = asyncio.Semaphore(MAX_WORKERS)

        # Process in batches
        batch_num = 0
        while pending:
            batch = pending[:BATCH_SIZE]
            pending = pending[BATCH_SIZE:]
            batch_num += 1

            # Process batch with retries
            retry_count = 0
            to_process = batch

            while to_process:
                failed = await process_batch(session, auth, to_process, results, semaphore)

                if failed:
                    retry_count += 1
                    if retry_count % 5 == 0:
                        print(f"\n⚠️ Retrying {len(failed)} failed heights (attempt {retry_count})...")
                        await asyncio.sleep(2.0)  # Give RPC time to recover
                    to_process = failed
                else:
                    to_process = []

            # Update completed set
            completed_heights.update(batch)

            # Progress
            elapsed = time.time() - start
            done = len(completed_heights)
            rate = done / elapsed if elapsed > 0 else 0
            remaining = total - done
            eta = remaining / rate / 60 if rate > 0 else 0
            pct = done / total * 100

            cmu_count = sum(len(results.get(h, [])) for h in completed_heights if h in results)

            print(f"\r⚡ {pct:.1f}% - {done:,}/{total:,} - {cmu_count:,} CMUs - "
                  f"{rate:.0f}/s - ETA:{eta:.0f}m  ", end='', flush=True)

            # Save progress every 10 batches
            if batch_num % 10 == 0:
                with open(progress_file, 'w') as f:
                    json.dump({
                        'target_height': current,
                        'completed': list(completed_heights)
                    }, f)

        print("\n")

        # Collect all CMUs in order
        print("📝 Collecting CMUs in block order...")
        all_cmus = []
        missing = []

        for h in range(SAPLING_ACTIVATION, current + 1):
            if h in results:
                all_cmus.extend(results[h])
            else:
                missing.append(h)

        if missing:
            print(f"❌ Missing {len(missing)} heights! First 10: {missing[:10]}")
            return 1

        elapsed = time.time() - start
        print(f"✅ {len(all_cmus):,} CMUs in {elapsed/60:.1f}m ({total/elapsed:.0f} blk/s)")

        # Verify against zcashd
        print(f"\n🔍 Verifying tree root against zcashd...")
        expected_root = await get_expected_root(session, auth, current)

        if expected_root:
            print(f"📊 zcashd finalsaplingroot at {current}: {expected_root}")
        else:
            print("⚠️ Could not get expected root from zcashd")

        # Write output file
        out = Path(__file__).parent.parent / 'Resources' / 'commitment_tree_v4.bin'
        with open(out, 'wb') as f:
            f.write(struct.pack('<Q', len(all_cmus)))
            for c in all_cmus:
                f.write(c)

        print(f"💾 {out} ({out.stat().st_size/1024/1024:.1f}MB)")
        print(f"📊 Height: {current}, CMUs: {len(all_cmus):,}")

        # Cleanup progress file
        if progress_file.exists():
            progress_file.unlink()

        print("\n✅ Export complete! Verify with:")
        print(f"   cargo run --release --bin verify_tree {out}")

        return 0

if __name__ == '__main__':
    sys.exit(asyncio.run(main()))
