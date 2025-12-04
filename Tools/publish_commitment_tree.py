#!/usr/bin/env python3
"""
Commitment Tree Publisher for ZipherX

This script:
1. Reads the EXISTING bundled tree (fast!)
2. Exports ONLY new CMUs since bundled tree height
3. Verifies the tree root matches the blockchain
4. Compresses it with zstd for efficient download
5. Creates a manifest.json with metadata
6. Commits and pushes to the ZipherX GitHub repository

Usage:
    python3 publish_commitment_tree.py [--no-push] [--full]

Options:
    --no-push   Don't push to git after creating tree
    --full      Export full tree from Sapling activation (slow, ~20 min)

Requirements:
    - Running zclassicd node with RPC enabled
    - Rust toolchain (for tree verification)
    - zstd compression tool
    - Git configured with push access to repository
"""

import asyncio
import aiohttp
import struct
import sys
import time
import json
import hashlib
import subprocess
import os
from pathlib import Path
from datetime import datetime, timezone

# Configuration
SAPLING_ACTIVATION = 476969
RPC_URL = "http://127.0.0.1:8023"
RPC_USER = ""
RPC_PASS = ""

# Batching settings - aggressive for speed
BATCH_SIZE = 100
MAX_WORKERS = 10

# Paths
PROJECT_ROOT = Path(__file__).parent.parent
RESOURCES_DIR = PROJECT_ROOT / "Resources"
TREE_FILE = RESOURCES_DIR / "commitment_tree.bin"
COMPRESSED_FILE = RESOURCES_DIR / "commitment_tree.bin.zst"
MANIFEST_FILE = RESOURCES_DIR / "commitment_tree_manifest.json"
FFI_DIR = PROJECT_ROOT / "Libraries" / "zipherx-ffi"

# These will be read from the manifest file (if exists) or use defaults
# The defaults match the original bundled tree shipped with app v1.0
DEFAULT_TREE_HEIGHT = 2926122
DEFAULT_TREE_CMU_COUNT = 1041891

def get_current_tree_info():
    """Read current tree height and CMU count from manifest or tree file"""
    # First try manifest
    if MANIFEST_FILE.exists():
        try:
            with open(MANIFEST_FILE) as f:
                manifest = json.load(f)
                return manifest['height'], manifest['cmu_count']
        except Exception as e:
            print(f"⚠️ Could not read manifest: {e}")

    # Then try reading from tree file header
    if TREE_FILE.exists():
        try:
            with open(TREE_FILE, 'rb') as f:
                cmu_count = struct.unpack('<Q', f.read(8))[0]
                # We don't know the height from file alone, use default
                print(f"⚠️ No manifest found, using tree file CMU count: {cmu_count}")
                return DEFAULT_TREE_HEIGHT, cmu_count
        except Exception as e:
            print(f"⚠️ Could not read tree file: {e}")

    # Fall back to defaults
    return DEFAULT_TREE_HEIGHT, DEFAULT_TREE_CMU_COUNT

def read_rpc_credentials():
    global RPC_USER, RPC_PASS
    # Check Library path first (Zipher.app location), then fallback to ~/.zclassic
    for conf_path in [Path.home() / "Library/Application Support/Zclassic/zclassic.conf",
                      Path.home() / ".zclassic" / "zclassic.conf"]:
        if conf_path.exists():
            for line in open(conf_path):
                if line.startswith('rpcuser='):
                    RPC_USER = line.strip().split('=', 1)[1]
                elif line.startswith('rpcpassword='):
                    RPC_PASS = line.strip().split('=', 1)[1]
            if RPC_USER and RPC_PASS:
                return True
    return False

async def batch_rpc_call(session, auth, requests, max_retries=5):
    batch_payload = []
    for i, (method, params) in enumerate(requests):
        batch_payload.append({
            "jsonrpc": "1.0",
            "id": i,
            "method": method,
            "params": params
        })

    for attempt in range(max_retries):
        try:
            async with session.post(
                RPC_URL,
                json=batch_payload,
                auth=auth,
                timeout=aiohttp.ClientTimeout(total=120)
            ) as resp:
                if resp.status == 200:
                    results = await resp.json()
                    sorted_results = sorted(results, key=lambda x: x.get('id', 0))
                    return [r.get('result') for r in sorted_results]
                elif resp.status == 500:
                    text = await resp.text()
                    if "Work queue depth exceeded" in text:
                        await asyncio.sleep(1.0 * (attempt + 1))
                        continue
        except asyncio.TimeoutError:
            await asyncio.sleep(0.5 * (attempt + 1))
        except Exception as e:
            print(f"\n⚠️ Batch RPC error: {e}")
            await asyncio.sleep(0.5 * (attempt + 1))
    return None

async def get_batch_cmus(session, auth, heights):
    hash_requests = [("getblockhash", [h]) for h in heights]
    hashes = await batch_rpc_call(session, auth, hash_requests)
    if hashes is None:
        return None

    block_requests = [("getblock", [h, 2]) for h in hashes if h]
    blocks = await batch_rpc_call(session, auth, block_requests)
    if blocks is None:
        return None

    results = {}
    for height, block in zip(heights, blocks):
        if not block or 'tx' not in block:
            results[height] = []
            continue

        cmus = []
        for tx in block['tx']:
            if isinstance(tx, dict) and tx.get('vShieldedOutput'):
                for out in tx['vShieldedOutput']:
                    if 'cmu' in out:
                        cmus.append(bytes(reversed(bytes.fromhex(out['cmu']))))
        results[height] = cmus
    return results

async def process_super_batch(session, auth, heights, semaphore):
    async with semaphore:
        return await get_batch_cmus(session, auth, heights)

async def get_block_info(session, auth, height):
    """Get block hash and finalsaplingroot for a height"""
    results = await batch_rpc_call(session, auth, [("getblockhash", [height])])
    if not results or not results[0]:
        return None, None

    block_hash = results[0]
    results = await batch_rpc_call(session, auth, [("getblockheader", [block_hash, True])])
    if not results or not results[0]:
        return block_hash, None

    return block_hash, results[0].get('finalsaplingroot')

async def export_tree_incremental(session, auth, target_height, current_height, current_cmu_count):
    """Export commitment tree incrementally from existing tree"""
    print(f"\n📝 INCREMENTAL export: height {current_height + 1:,} to {target_height:,}")
    print(f"   Current tree: height {current_height:,} with {current_cmu_count:,} CMUs")

    # Read existing tree
    if not TREE_FILE.exists():
        print(f"❌ Tree file not found at {TREE_FILE}")
        return None, 0

    print(f"   Reading existing tree...")
    with open(TREE_FILE, 'rb') as f:
        existing_data = f.read()

    existing_cmu_count = struct.unpack('<Q', existing_data[:8])[0]
    print(f"   Existing tree has {existing_cmu_count:,} CMUs")

    if existing_cmu_count != current_cmu_count:
        print(f"⚠️ Warning: Manifest says {current_cmu_count:,} CMUs but file has {existing_cmu_count:,}")

    # Calculate blocks to fetch
    start_height = current_height + 1
    blocks_to_fetch = target_height - current_height

    if blocks_to_fetch <= 0:
        print(f"✅ Tree is already up to date!")
        return TREE_FILE, existing_cmu_count

    print(f"   Fetching {blocks_to_fetch:,} new blocks...")

    temp_file = TREE_FILE.with_suffix('.tmp')
    start_time = time.time()
    semaphore = asyncio.Semaphore(MAX_WORKERS)

    # Copy existing data to temp file
    with open(temp_file, 'wb') as f:
        f.write(existing_data)

    f_out = open(temp_file, 'ab')  # Append mode

    try:
        new_cmus = 0
        last_written_height = current_height
        all_heights = list(range(start_height, target_height + 1))

        for super_batch_start in range(0, len(all_heights), BATCH_SIZE * MAX_WORKERS):
            super_batch_heights = all_heights[super_batch_start:super_batch_start + BATCH_SIZE * MAX_WORKERS]

            tasks = []
            for batch_start in range(0, len(super_batch_heights), BATCH_SIZE):
                batch_heights = super_batch_heights[batch_start:batch_start + BATCH_SIZE]
                tasks.append(process_super_batch(session, auth, batch_heights, semaphore))

            batch_results = await asyncio.gather(*tasks)

            merged = {}
            for result in batch_results:
                if result:
                    merged.update(result)

            for h in sorted(merged.keys()):
                if h == last_written_height + 1:
                    cmus = merged[h]
                    for cmu in cmus:
                        f_out.write(cmu)
                        new_cmus += 1
                    last_written_height = h
                else:
                    print(f"\n⚠️ Height gap at {h} (last: {last_written_height})")

            elapsed = time.time() - start_time
            done = last_written_height - current_height
            rate = done / elapsed if elapsed > 0 else 0
            remaining = target_height - last_written_height
            eta = remaining / rate / 60 if rate > 0 else 0
            pct = done / blocks_to_fetch * 100

            print(f"\r⚡ {pct:.1f}% - {last_written_height:,}/{target_height:,} - "
                  f"+{new_cmus:,} CMUs - {rate:.0f} blk/s - ETA:{eta:.1f}m  ",
                  end='', flush=True)

        print("\n")

        if last_written_height != target_height:
            print(f"❌ Incomplete! Last: {last_written_height}, expected: {target_height}")
            f_out.close()
            return None, 0

        f_out.close()

        # Update CMU count in header
        total_cmus = existing_cmu_count + new_cmus
        with open(temp_file, 'r+b') as f:
            f.seek(0)
            f.write(struct.pack('<Q', total_cmus))

        # Replace original file
        if TREE_FILE.exists():
            TREE_FILE.unlink()
        temp_file.rename(TREE_FILE)

        elapsed = time.time() - start_time
        print(f"✅ Added {new_cmus:,} new CMUs in {elapsed:.1f}s")
        print(f"   Total: {total_cmus:,} CMUs")

        return TREE_FILE, total_cmus

    except Exception as e:
        f_out.close()
        print(f"\n❌ Export error: {e}")
        import traceback
        traceback.print_exc()
        return None, 0

async def export_tree_full(session, auth, target_height):
    """Export full commitment tree from Sapling activation (slow!)"""
    print(f"\n📝 FULL export from height {SAPLING_ACTIVATION:,} to {target_height:,}")
    print(f"   ⚠️ This will take ~20 minutes for ~2.4M blocks")

    temp_file = TREE_FILE.with_suffix('.tmp')
    if temp_file.exists():
        temp_file.unlink()

    start_time = time.time()
    semaphore = asyncio.Semaphore(MAX_WORKERS)

    f_out = open(temp_file, 'wb')
    f_out.write(struct.pack('<Q', 0))  # Placeholder

    try:
        total_cmus = 0
        last_written_height = SAPLING_ACTIVATION - 1
        total = target_height - SAPLING_ACTIVATION + 1
        all_heights = list(range(SAPLING_ACTIVATION, target_height + 1))

        for super_batch_start in range(0, len(all_heights), BATCH_SIZE * MAX_WORKERS):
            super_batch_heights = all_heights[super_batch_start:super_batch_start + BATCH_SIZE * MAX_WORKERS]

            tasks = []
            for batch_start in range(0, len(super_batch_heights), BATCH_SIZE):
                batch_heights = super_batch_heights[batch_start:batch_start + BATCH_SIZE]
                tasks.append(process_super_batch(session, auth, batch_heights, semaphore))

            batch_results = await asyncio.gather(*tasks)

            merged = {}
            for result in batch_results:
                if result:
                    merged.update(result)

            for h in sorted(merged.keys()):
                if h == last_written_height + 1:
                    cmus = merged[h]
                    for cmu in cmus:
                        f_out.write(cmu)
                        total_cmus += 1
                    last_written_height = h
                else:
                    print(f"\n⚠️ Height gap at {h} (last: {last_written_height})")

            elapsed = time.time() - start_time
            done = last_written_height - SAPLING_ACTIVATION + 1
            rate = done / elapsed if elapsed > 0 else 0
            remaining = target_height - last_written_height
            eta = remaining / rate / 60 if rate > 0 else 0
            pct = done / total * 100

            print(f"\r⚡ {pct:.1f}% - {last_written_height:,}/{target_height:,} - "
                  f"{total_cmus:,} CMUs - {rate:.0f} blk/s - ETA:{eta:.1f}m  ",
                  end='', flush=True)

            if super_batch_start % (BATCH_SIZE * MAX_WORKERS * 10) == 0:
                f_out.flush()

        print("\n")

        if last_written_height != target_height:
            print(f"❌ Incomplete! Last: {last_written_height}, expected: {target_height}")
            f_out.close()
            return None, 0

        f_out.seek(0)
        f_out.write(struct.pack('<Q', total_cmus))
        f_out.close()

        if TREE_FILE.exists():
            TREE_FILE.unlink()
        temp_file.rename(TREE_FILE)

        elapsed = time.time() - start_time
        print(f"✅ Exported {total_cmus:,} CMUs in {elapsed/60:.1f}m")

        return TREE_FILE, total_cmus

    except Exception as e:
        f_out.close()
        print(f"\n❌ Export error: {e}")
        import traceback
        traceback.print_exc()
        return None, 0

def verify_tree_with_rust(tree_path, expected_root):
    """Verify tree root using Rust binary"""
    print(f"\n🔍 Verifying tree with Rust...")

    # Build the verifier if needed
    verifier_path = FFI_DIR / "target" / "release" / "verify_tree_correct"
    if not verifier_path.exists():
        print("   Building verifier...")
        result = subprocess.run(
            ["cargo", "build", "--release", "--bin", "verify_tree_correct"],
            cwd=FFI_DIR,
            capture_output=True,
            text=True
        )
        if result.returncode != 0:
            print(f"❌ Build failed: {result.stderr}")
            return False, None

    # Run verifier
    result = subprocess.run(
        [str(verifier_path), str(tree_path)],
        capture_output=True,
        text=True
    )

    if result.returncode != 0:
        print(f"❌ Verification failed: {result.stderr}")
        return False, None

    # Parse output to get computed root
    computed_root = None
    for line in result.stdout.split('\n'):
        if "display format" in line.lower():
            parts = line.split(':')
            if len(parts) >= 2:
                computed_root = parts[-1].strip()

    print(f"   Expected root: {expected_root}")
    print(f"   Computed root: {computed_root}")

    if computed_root and computed_root == expected_root:
        print("   ✅ Root verification PASSED!")
        return True, computed_root
    else:
        print("   ❌ Root verification FAILED!")
        return False, computed_root

def compute_sha256(file_path):
    """Compute SHA256 checksum of a file"""
    sha256 = hashlib.sha256()
    with open(file_path, 'rb') as f:
        for chunk in iter(lambda: f.read(65536), b''):
            sha256.update(chunk)
    return sha256.hexdigest()

def compress_tree(input_path, output_path):
    """Compress tree with zstd"""
    print(f"\n📦 Compressing tree with zstd...")

    # Check if zstd is available
    result = subprocess.run(["which", "zstd"], capture_output=True)
    if result.returncode != 0:
        print("   zstd not found, trying to install...")
        subprocess.run(["brew", "install", "zstd"], check=True)

    # Compress with high compression level
    result = subprocess.run(
        ["zstd", "-19", "-f", str(input_path), "-o", str(output_path)],
        capture_output=True,
        text=True
    )

    if result.returncode != 0:
        print(f"❌ Compression failed: {result.stderr}")
        return False

    original_size = input_path.stat().st_size
    compressed_size = output_path.stat().st_size
    ratio = compressed_size / original_size * 100

    print(f"   Original:   {original_size / 1024 / 1024:.1f} MB")
    print(f"   Compressed: {compressed_size / 1024 / 1024:.1f} MB ({ratio:.1f}%)")

    return True

def create_manifest(height, cmu_count, block_hash, tree_root, tree_checksum, compressed_checksum):
    """Create manifest.json with tree metadata"""
    manifest = {
        "version": 2,
        "created_at": datetime.now(timezone.utc).isoformat(),
        "height": height,
        "cmu_count": cmu_count,
        "block_hash": block_hash,
        "tree_root": tree_root,
        "files": {
            "uncompressed": {
                "name": "commitment_tree.bin",
                "size": TREE_FILE.stat().st_size,
                "sha256": tree_checksum
            },
            "compressed": {
                "name": "commitment_tree.bin.zst",
                "size": COMPRESSED_FILE.stat().st_size,
                "sha256": compressed_checksum
            }
        }
    }

    with open(MANIFEST_FILE, 'w') as f:
        json.dump(manifest, f, indent=2)

    print(f"\n📋 Created manifest: {MANIFEST_FILE}")
    return manifest

def git_commit_and_push(height, cmu_count, tree_root, no_push=False):
    """Commit and push the new tree to GitHub"""
    print(f"\n📤 Committing to git...")

    os.chdir(PROJECT_ROOT)

    # Check if there are changes to commit
    result = subprocess.run(["git", "status", "--porcelain", "Resources/"], capture_output=True, text=True)
    if not result.stdout.strip():
        print("   ℹ️ No changes to commit (tree already up to date)")
        return True

    # Add files
    files_to_add = [
        "Resources/commitment_tree.bin",
        "Resources/commitment_tree.bin.zst",
        "Resources/commitment_tree_manifest.json"
    ]

    for f in files_to_add:
        file_path = PROJECT_ROOT / f
        if file_path.exists():
            subprocess.run(["git", "add", f], check=True)

    # Create detailed commit message
    commit_msg = f"""Update commitment tree to height {height:,}

Tree Statistics:
- Height: {height:,}
- CMU Count: {cmu_count:,}
- Tree Root: {tree_root}

This tree allows ZipherX users to sync faster by skipping historical
block scanning. The app automatically downloads this on first install.

To use in app bundle (optional):
1. Copy Resources/commitment_tree.bin to app bundle
2. Update Constants.swift:
   - bundledTreeHeight = {height}
   - bundledTreeCMUCount = {cmu_count}
   - bundledTreeRoot = "{tree_root}"
3. Rebuild app

🤖 Generated with publish_commitment_tree.py"""

    result = subprocess.run(
        ["git", "commit", "-m", commit_msg],
        capture_output=True,
        text=True
    )

    if result.returncode != 0:
        if "nothing to commit" in result.stdout or "nothing to commit" in result.stderr:
            print("   ℹ️ No changes to commit")
            return True
        print(f"   ⚠️ Commit failed: {result.stderr}")
        return False

    print(f"   ✅ Committed")

    if no_push:
        print("   ⏭️ Skipping push (--no-push flag)")
        return True

    # Push
    print("   Pushing to remote...")
    result = subprocess.run(["git", "push"], capture_output=True, text=True)

    if result.returncode != 0:
        print(f"   ⚠️ Push failed: {result.stderr}")
        print(f"   You can manually push with: git push")
        return False

    print("   ✅ Pushed to remote")
    return True

async def main():
    print("=" * 60)
    print("🌲 ZipherX Commitment Tree Publisher")
    print("=" * 60)

    no_push = "--no-push" in sys.argv
    full_export = "--full" in sys.argv

    if not read_rpc_credentials():
        print("❌ No RPC credentials found")
        return 1

    auth = aiohttp.BasicAuth(RPC_USER, RPC_PASS)
    conn = aiohttp.TCPConnector(limit=50, force_close=False, enable_cleanup_closed=True)

    async with aiohttp.ClientSession(connector=conn) as session:
        # Get current chain info
        result = await batch_rpc_call(session, auth, [("getblockchaininfo", [])])
        if not result or not result[0]:
            print("❌ RPC failed")
            return 1

        info = result[0]
        chain_height = info['blocks']

        # Get current tree info from manifest or file
        tree_height, tree_cmu_count = get_current_tree_info()

        print(f"\n📊 Chain height: {chain_height:,}")
        print(f"📊 Current tree: height {tree_height:,} ({tree_cmu_count:,} CMUs)")

        blocks_behind = chain_height - tree_height
        print(f"📊 Blocks to add: {blocks_behind:,}")

        if blocks_behind <= 0:
            print("✅ Tree is already up to date!")
            return 0

        # Get block info for chain tip
        block_hash, expected_root = await get_block_info(session, auth, chain_height)
        if not expected_root:
            print("❌ Could not get finalsaplingroot")
            return 1

        print(f"📊 Block hash: {block_hash}")
        print(f"📊 Expected root: {expected_root}")

        # Export tree
        if full_export:
            tree_path, cmu_count = await export_tree_full(session, auth, chain_height)
        else:
            tree_path, cmu_count = await export_tree_incremental(session, auth, chain_height, tree_height, tree_cmu_count)

        if not tree_path:
            return 1

        # Verify with Rust
        verified, computed_root = verify_tree_with_rust(tree_path, expected_root)
        if not verified:
            print("\n❌ Tree verification failed - aborting")
            return 1

        # Compute checksum of uncompressed tree
        print(f"\n🔐 Computing checksums...")
        tree_checksum = compute_sha256(tree_path)
        print(f"   Tree SHA256: {tree_checksum}")

        # Compress
        if not compress_tree(tree_path, COMPRESSED_FILE):
            return 1

        # Checksum of compressed file
        compressed_checksum = compute_sha256(COMPRESSED_FILE)
        print(f"   Compressed SHA256: {compressed_checksum}")

        # Create manifest
        manifest = create_manifest(
            chain_height,
            cmu_count,
            block_hash,
            computed_root,
            tree_checksum,
            compressed_checksum
        )

        # Print summary
        print(f"\n" + "=" * 60)
        print("📊 TREE PUBLISHED SUCCESSFULLY")
        print("=" * 60)
        print(f"   Height:     {chain_height:,}")
        print(f"   CMU Count:  {cmu_count:,}")
        print(f"   Tree Root:  {computed_root}")
        print(f"   Block Hash: {block_hash}")
        print()
        print("✅ App will automatically download this tree from GitHub!")
        print("   No app update required - users get faster sync automatically.")
        print("=" * 60)

        # Git commit and push
        if git_commit_and_push(chain_height, cmu_count, computed_root, no_push):
            print(f"\n✅ Tree published successfully!")
        else:
            print(f"\n⚠️ Tree created but git push failed")

        return 0

if __name__ == '__main__':
    sys.exit(asyncio.run(main()))
