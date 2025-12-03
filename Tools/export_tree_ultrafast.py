#!/usr/bin/env python3
"""
ULTRA-FAST Sapling Tree Export v4

Key: True parallel workers with adaptive rate limiting
"""

import asyncio
import aiohttp
import struct
import sys
import time
from pathlib import Path
from collections import deque

SAPLING_ACTIVATION = 476969
RPC_URL = "http://127.0.0.1:8023"
RPC_USER = ""
RPC_PASS = ""

# Adaptive concurrency
MIN_WORKERS = 8
MAX_WORKERS = 32
INITIAL_WORKERS = 16

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

class AdaptiveRPC:
    def __init__(self, session, auth):
        self.session = session
        self.auth = auth
        self.workers = INITIAL_WORKERS
        self.errors = deque(maxlen=10)
        self.lock = asyncio.Lock()

    async def adjust(self, success):
        async with self.lock:
            now = time.time()
            if not success:
                self.errors.append(now)
                self.workers = max(MIN_WORKERS, self.workers - 4)
            elif len(self.errors) == 0 or now - self.errors[-1] > 3:
                self.workers = min(MAX_WORKERS, self.workers + 1)

    async def call(self, method, *params):
        payload = {"jsonrpc": "1.0", "id": 1, "method": method, "params": list(params)}
        for attempt in range(5):
            try:
                async with self.session.post(RPC_URL, json=payload, auth=self.auth,
                                            timeout=aiohttp.ClientTimeout(total=30)) as resp:
                    if resp.status == 500:
                        text = await resp.text()
                        if "Work queue depth exceeded" in text:
                            await self.adjust(False)
                            await asyncio.sleep(0.3 * (attempt + 1))
                            continue
                    if resp.status == 200:
                        await self.adjust(True)
                        return (await resp.json()).get('result')
            except:
                await asyncio.sleep(0.2 * (attempt + 1))
        return None

async def get_block_cmus(rpc, height):
    block_hash = await rpc.call("getblockhash", height)
    if not block_hash:
        return height, []
    block = await rpc.call("getblock", block_hash, 2)
    if not block or 'tx' not in block:
        return height, []

    cmus = []
    for tx in block['tx']:
        if isinstance(tx, dict) and tx.get('vShieldedOutput'):
            for out in tx['vShieldedOutput']:
                if 'cmu' in out:
                    cmus.append(bytes(reversed(bytes.fromhex(out['cmu']))))
    return height, cmus

async def worker(rpc, queue, results, stats):
    while True:
        try:
            height = await asyncio.wait_for(queue.get(), timeout=0.5)
        except asyncio.TimeoutError:
            if queue.empty():
                break
            continue
        h, cmus = await get_block_cmus(rpc, height)
        results[h] = cmus
        stats['done'] += 1
        stats['cmus'] += len(cmus)
        queue.task_done()

async def main():
    print("🚀 ULTRA-FAST Export v4 (adaptive workers)")
    print("=" * 60)

    if not read_rpc_credentials():
        print("❌ No RPC credentials")
        return 1

    auth = aiohttp.BasicAuth(RPC_USER, RPC_PASS)
    conn = aiohttp.TCPConnector(limit=100)

    async with aiohttp.ClientSession(connector=conn) as session:
        rpc = AdaptiveRPC(session, auth)

        info = await rpc.call("getblockchaininfo")
        if not info:
            print("❌ RPC failed")
            return 1

        current = info['blocks']
        total = current - SAPLING_ACTIVATION + 1

        print(f"📊 Blocks: {total:,} (height {current:,})")

        results = {}
        stats = {'done': 0, 'cmus': 0}
        start = time.time()

        # Fill queue with all heights
        queue = asyncio.Queue()
        for h in range(SAPLING_ACTIVATION, current + 1):
            await queue.put(h)

        # Spawn workers dynamically
        workers = set()
        last_print = 0

        while stats['done'] < total:
            # Adjust worker count
            target = rpc.workers
            while len(workers) < target:
                w = asyncio.create_task(worker(rpc, queue, results, stats))
                workers.add(w)
                w.add_done_callback(workers.discard)

            # Progress
            if stats['done'] - last_print >= 1000 or stats['done'] == total:
                elapsed = time.time() - start
                rate = stats['done'] / elapsed if elapsed > 0 else 0
                eta = (total - stats['done']) / rate / 60 if rate > 0 else 0
                pct = stats['done'] / total * 100
                print(f"\r⚡ {pct:.1f}% - {stats['done']:,}/{total:,} - "
                      f"{stats['cmus']:,} CMUs - {rate:.0f}/s - "
                      f"w:{len(workers)}/{rpc.workers} - ETA:{eta:.0f}m  ", end='', flush=True)
                last_print = stats['done']

            await asyncio.sleep(0.1)

        # Wait for stragglers
        await queue.join()
        for w in workers:
            w.cancel()

        print("\n")

        # Collect ordered
        all_cmus = []
        for h in range(SAPLING_ACTIVATION, current + 1):
            all_cmus.extend(results.get(h, []))

        elapsed = time.time() - start
        print(f"✅ {len(all_cmus):,} CMUs in {elapsed/60:.1f}m ({total/elapsed:.0f} blk/s)")

        if len(all_cmus) < 100000:
            print("❌ Too few CMUs!")
            return 1

        out = Path(__file__).parent.parent / 'Resources' / 'commitment_tree_v2.bin'
        with open(out, 'wb') as f:
            f.write(struct.pack('<Q', len(all_cmus)))
            for c in all_cmus:
                f.write(c)

        print(f"💾 {out} ({out.stat().st_size/1024/1024:.1f}MB)")
        return 0

if __name__ == '__main__':
    sys.exit(asyncio.run(main()))
