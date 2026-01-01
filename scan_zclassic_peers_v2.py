#!/usr/bin/env python3
"""
Try different protocol versions and longer timeouts to find working Zclassic peers.
"""

import socket
import struct
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed

NETWORK_MAGIC = bytes.fromhex("24279e24")  # Zclassic

# Core trusted peers
CORE_PEERS = [
    ("37.187.76.79", 8033),
    ("185.205.246.161", 8033),
    ("140.174.189.3", 8033),
    ("205.209.104.118", 8033),
    ("74.50.74.102", 8033),
    ("140.174.189.17", 8033),
]

def create_address(addr_str: str, port: int, services: int) -> bytes:
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

def create_version_message(start_height: int, protocol_version: int) -> bytes:
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
    payload += b'\x01'

    return payload

def create_message(command: str, payload: bytes = b"") -> bytes:
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

def recv_all(sock, n, timeout=10):
    sock.settimeout(timeout)
    data = b''
    while len(data) < n:
        try:
            chunk = sock.recv(n - len(data))
        except socket.timeout:
            return None
        if not chunk:
            return None
        data += chunk
    return data

def test_peer_with_version(host: str, port: int, protocol_version: int):
    """Test peer with specific protocol version"""
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        sock.settimeout(10)  # Longer timeout

        sock.connect((host, port))
        time.sleep(0.2)  # Wait longer for connection to stabilize

        version_msg = create_version_message(2961027, protocol_version=protocol_version)
        msg = create_message('version', version_msg)
        sock.sendall(msg)

        # Wait for response
        header = recv_all(sock, 24, timeout=10)
        if not header:
            return f"v{protocol_version}: No response"

        magic = header[:4]
        if magic != NETWORK_MAGIC:
            return f"v{protocol_version}: Bad magic"

        command = header[4:16].rstrip(b'\x00').decode('ascii', errors='ignore')
        length = struct.unpack('<I', header[16:20])[0]

        if length > 0 and length < 100000:
            payload = recv_all(sock, length, timeout=10)
            if payload:
                if command == 'version':
                    peer_version = struct.unpack('<I', payload[:4])[0]
                    return f"✅ v{protocol_version} → peer v{peer_version}"
                else:
                    return f"v{protocol_version}: Got '{command}'"
            else:
                return f"v{protocol_version}: No payload"
        else:
            return f"v{protocol_version}: Empty"

    except socket.timeout:
        return f"v{protocol_version}: Timeout"
    except ConnectionRefusedError:
        return f"v{protocol_version}: Refused"
    except Exception as e:
        return f"v{protocol_version}: {str(e)[:30]}"
    finally:
        try:
            sock.close()
        except:
            pass

def main():
    print("=" * 70)
    print("Zclassic Peer Protocol Version Scanner")
    print("Trying different protocol versions...")
    print("=" * 70)
    print()

    # Try different protocol versions
    protocol_versions = [170009, 170010, 170011, 170012, 170013, 170014]

    for host, port in CORE_PEERS:
        print(f"Testing {host}:{port}...")

        for version in protocol_versions:
            result = test_peer_with_version(host, port, version)
            print(f"  {result}")

            if "✅" in result:
                print(f"\n🎉 FOUND WORKING PEER: {host}:{port}")
                print(f"   Using protocol version: {version}")
                print()

        print()

if __name__ == '__main__':
    main()
