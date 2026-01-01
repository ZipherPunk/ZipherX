#!/usr/bin/env python3
"""
Scan all known Zclassic peers to find which ones accept P2P connections.
This helps identify working peers when the network is unstable.
"""

import socket
import struct
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from typing import List, Tuple

NETWORK_MAGIC = bytes.fromhex("24279e24")  # Zclassic

# All known Zclassic peers from various sources
PEER_LIST = [
    # Zelcore InsightAPI working peers (MagicBean 2.1.x)
    ("37.187.76.79", 8033),
    ("157.90.223.151", 8033),
    ("51.178.179.75", 8033),
    ("162.55.92.62", 8033),
    ("205.209.104.118", 8033),
    ("74.50.74.102", 8033),
    ("185.205.246.161", 8033),
    ("140.174.189.3", 8033),

    # Additional known Zclassic nodes
    ("140.174.189.17", 8033),
    ("213.32.95.42", 8033),
    ("188.165.224.26", 8033),
    ("95.179.131.117", 8033),
    ("45.77.216.198", 8033),
    ("212.23.222.231", 8033),
    ("107.152.45.101", 8033),
    ("185.16.61.195", 8033),
    ("208.180.115.155", 8033),
    ("89.58.7.94", 8033),
    ("64.32.48.102", 8033),
    ("92.135.81.99", 8033),

    # Try some alternative ports in case peers use non-standard ports
    ("37.187.76.79", 8333),
    ("185.205.246.161", 8333),
    ("140.174.189.3", 8333),
    ("205.209.104.118", 8333),
]

@dataclass
class PeerResult:
    host: str
    port: int
    status: str
    peer_version: int = 0
    user_agent: str = ""
    response_time: float = 0.0
    error: str = ""

def create_address(addr_str: str, port: int, services: int) -> bytes:
    """Create a CAddress structure (26 bytes for IPv4)"""
    addr = struct.pack('<Q', services)

    if ':' in addr_str:
        import socket as socket_mod
        addr_bytes = socket_mod.inet_pton(socket_mod.AF_INET6, addr_str)
    else:
        import socket as socket_mod
        addr_bytes = socket_mod.inet_pton(socket_mod.AF_INET, addr_str)
        addr_bytes = b'\x00' * 10 + b'\xff\xff' + addr_bytes

    addr += addr_bytes
    addr += struct.pack('>H', port)
    return addr

def create_version_message(start_height: int, protocol_version: int = 170011) -> bytes:
    """Create Zclassic version message"""
    nTime = int(time.time())
    nLocalServices = 1
    nLocalHostNonce = 0
    strSubVersion = b'/MagicBean:2.1.1/'

    payload = struct.pack('<I', protocol_version)
    payload += struct.pack('<Q', nLocalServices)
    payload += struct.pack('<Q', nTime)
    payload += create_address("0.0.0.0", 0, 0)
    payload += create_address("0.0.0.0", 0, 0)
    payload += struct.pack('<Q', nLocalHostNonce)
    payload += bytes([len(strSubVersion)]) + strSubVersion
    payload += struct.pack('<I', start_height)
    payload += b'\x01'  # Relay flag

    return payload

def create_message(command: str, payload: bytes = b"") -> bytes:
    """Create P2P message with Zclassic network magic"""
    command_bytes = command.encode('ascii').ljust(12, b'\x00')
    length = struct.pack('<I', len(payload))

    if payload:
        import hashlib
        hash1 = hashlib.sha256(payload).digest()
        hash2 = hashlib.sha256(hash1).digest()
        checksum = hash2[:4]
    else:
        checksum = b'\x00' * 4

    header = NETWORK_MAGIC + command_bytes + length + checksum
    return header + payload

def recv_all(sock, n, timeout=5):
    """Receive exactly n bytes"""
    sock.settimeout(timeout)
    data = b''
    while len(data) < n:
        try:
            chunk = sock.recv(n - len(data))
        except socket.timeout:
            raise Exception(f"Timeout after {len(data)}/{n} bytes")
        if not chunk:
            raise Exception(f"Connection closed ({len(data)}/{n} bytes received)")
        data += chunk
    return data

def recv_message(sock):
    """Receive P2P message"""
    try:
        header = recv_all(sock, 24, timeout=10)
        magic = header[:4]
        if magic != NETWORK_MAGIC:
            raise Exception(f"Bad magic: {magic.hex()}")

        command = header[4:16].rstrip(b'\x00').decode('ascii', errors='ignore')
        length = struct.unpack('<I', header[16:20])[0]

        if length > 0 and length < 1000000:
            payload = recv_all(sock, length, timeout=10)
        else:
            payload = b''

        return command, payload
    except Exception as e:
        raise Exception(f"Receive failed: {e}")

def test_peer(host: str, port: int, start_height: int) -> PeerResult:
    """Test a single peer connection"""
    start_time = time.time()
    peer_version = 0
    user_agent = ""
    error_msg = ""

    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)

        # Try to connect with 5 second timeout
        sock.settimeout(5)
        try:
            sock.connect((host, port))
        except socket.timeout:
            return PeerResult(host, port, "TIMEOUT", error="Connection timeout")
        except ConnectionRefusedError:
            return PeerResult(host, port, "REFUSED", error="Connection refused")
        except socket.error as e:
            return PeerResult(host, port, "ERROR", error=str(e))

        # Small delay to let connection stabilize
        time.sleep(0.1)

        # Send version message
        version_msg = create_version_message(start_height, protocol_version=170011)
        msg = create_message('version', version_msg)
        sock.sendall(msg)

        # Wait for version/verack
        try:
            command, payload = recv_message(sock)

            if command == 'version':
                # Parse version message
                if len(payload) >= 4:
                    peer_version = struct.unpack('<I', payload[:4])[0]

                # Try to extract user agent
                if len(payload) > 4 + 8 + 8 + 26 + 26 + 8:  # After standard header fields
                    ua_length = payload[4 + 8 + 8 + 26 + 26 + 8]
                    if len(payload) > 4 + 8 + 8 + 26 + 26 + 8 + 1 + ua_length:
                        user_agent_bytes = payload[4 + 8 + 8 + 26 + 26 + 8 + 1:4 + 8 + 8 + 26 + 26 + 8 + 1 + ua_length]
                        try:
                            user_agent = user_agent_bytes.decode('ascii', errors='ignore')
                        except:
                            user_agent = "<?>"

                # Send verack
                sock.sendall(create_message('verack', b''))

                response_time = time.time() - start_time

                # Check if it's a valid Zclassic peer
                if 170010 <= peer_version <= 170012:
                    return PeerResult(host, port, "WORKING", peer_version, user_agent, response_time)
                else:
                    return PeerResult(host, port, "WRONG_VERSION", peer_version, user_agent, response_time)

            elif command == 'verack':
                return PeerResult(host, port, "VERACK_FIRST", error="Got verack before version")
            else:
                return PeerResult(host, port, "UNEXPECTED", error=f"Got '{command}' first")

        except Exception as e:
            error_msg = str(e)
            if "Connection closed" in error_msg:
                return PeerResult(host, port, "CLOSED", error=error_msg)
            elif "Connection reset" in error_msg:
                return PeerResult(host, port, "RESET", error=error_msg)
            else:
                return PeerResult(host, port, "HANDSHAKE_FAIL", error=error_msg)

    except Exception as e:
        return PeerResult(host, port, "EXCEPTION", error=str(e))
    finally:
        try:
            sock.close()
        except:
            pass

def main():
    start_height = 2961027  # Current approximate height

    print("=" * 70)
    print("Zclassic Peer Connectivity Scanner")
    print(f"Testing {len(PEER_LIST)} peer addresses...")
    print("=" * 70)
    print()

    # Test peers in parallel (faster)
    working_peers: List[PeerResult] = []
    failed_peers: List[PeerResult] = []

    with ThreadPoolExecutor(max_workers=10) as executor:
        # Submit all tasks
        future_to_peer = {
            executor.submit(test_peer, host, port, start_height): (host, port)
            for host, port in PEER_LIST
        }

        # Collect results as they complete
        for future in as_completed(future_to_peer):
            host, port = future_to_peer[future]
            try:
                result = future.result()
                status_emoji = {
                    "WORKING": "✅",
                    "WRONG_VERSION": "⚠️",
                    "TIMEOUT": "⏱️",
                    "REFUSED": "🚫",
                    "CLOSED": "❌",
                    "RESET": "🔄",
                    "ERROR": "💥",
                    "HANDSHAKE_FAIL": "⛔",
                    "UNEXPECTED": "❓",
                    "VERACK_FIRST": "❓",
                    "EXCEPTION": "💥"
                }.get(result.status, "❓")

                print(f"{status_emoji} {host}:{port} - {result.status}", end="")

                if result.status == "WORKING":
                    print(f" (v{result.peer_version}, {result.user_agent}, {result.response_time:.2f}s)")
                    working_peers.append(result)
                elif result.status == "WRONG_VERSION":
                    print(f" (v{result.peer_version}, {result.user_agent})")
                    failed_peers.append(result)
                else:
                    print(f" - {result.error}")
                    failed_peers.append(result)

            except Exception as e:
                print(f"💥 {host}:{port} - CRASH: {e}")
                failed_peers.append(PeerResult(host, port, "CRASH", error=str(e)))

    print()
    print("=" * 70)
    print("SUMMARY")
    print("=" * 70)
    print(f"Total tested: {len(PEER_LIST)}")
    print(f"Working: {len(working_peers)} ✅")
    print(f"Failed: {len(failed_peers)} ❌")
    print()

    if working_peers:
        print("✅ WORKING PEERS:")
        print("-" * 70)
        for peer in working_peers:
            print(f"  {peer.host}:{peer.port}")
            print(f"    Version: {peer.peer_version}, User-Agent: {peer.user_agent}")
            print(f"    Response time: {peer.response_time:.2f}s")
        print()

    # Group failures by type
    failure_types = {}
    for peer in failed_peers:
        if peer.status not in failure_types:
            failure_types[peer.status] = []
        failure_types[peer.status].append(peer)

    if failure_types:
        print("❌ FAILED PEERS (by error type):")
        print("-" * 70)
        for status, peers in sorted(failure_types.items()):
            print(f"  {status}: {len(peers)} peers")
            for peer in peers[:5]:  # Show first 5
                print(f"    - {peer.host}:{peer.port}")
            if len(peers) > 5:
                print(f"    ... and {len(peers) - 5} more")
            print()

    if working_peers:
        print("=" * 70)
        print("📋 LIST FOR APP (working peers only):")
        print("=" * 70)
        for peer in working_peers:
            print(f'        ("{peer.host}", {peer.port}),')
        print()

        print("=" * 70)
        print("📋 CURL COMMAND TO TEST A PEER:")
        print("=" * 70)
        peer = working_peers[0]
        print(f"# Test {peer.host}:{peer.port}")
        print(f"nc -zv {peer.host} {peer.port}")
        print()

if __name__ == '__main__':
    main()
