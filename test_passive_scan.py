#!/usr/bin/env python3
"""
Passive scan - just connect and wait for peer to send version first.
Some P2P implementations send version immediately upon connection.
"""

import socket
import struct
import time

NETWORK_MAGIC = bytes.fromhex("24279e24")  # Zclassic

CORE_PEERS = [
    ("37.187.76.79", 8033),
    ("185.205.246.161", 8033),
    ("140.174.189.3", 8033),
    ("205.209.104.118", 8033),
]

def recv_all(sock, n, timeout=5):
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

def test_peer_passive(host: str, port: int):
    """Connect and just wait - don't send anything"""
    try:
        print(f"  Connecting to {host}:{port}...")
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        sock.settimeout(15)

        sock.connect((host, port))
        print(f"  Connected! Waiting for peer to send data...")

        # Wait for peer to send version message first
        header = recv_all(sock, 24, timeout=15)
        if not header:
            return "Timed out waiting for data"

        magic = header[:4]
        if magic != NETWORK_MAGIC:
            return f"Bad magic: {magic.hex()}"

        command = header[4:16].rstrip(b'\x00').decode('ascii', errors='ignore')
        length = struct.unpack('<I', header[16:20])[0]

        print(f"  Got '{command}' message ({length} bytes)")

        if length > 0 and length < 100000:
            payload = recv_all(sock, length, timeout=15)
            if payload and command == 'version':
                peer_version = struct.unpack('<I', payload[:4])[0]
                return f"✅ Peer sent version v{peer_version} first!"

        return f"Peer sent '{command}' first"

    except socket.timeout:
        return "Timeout (15s)"
    except ConnectionRefusedError:
        return "Connection refused"
    except Exception as e:
        return f"Error: {e}"
    finally:
        try:
            sock.close()
        except:
            pass

def main():
    print("=" * 70)
    print("Passive Zclassic Peer Scanner")
    print("Just connect and wait - don't send version first")
    print("=" * 70)
    print()

    for host, port in CORE_PEERS:
        print(f"Testing {host}:{port}")
        result = test_peer_passive(host, port)
        print(f"  Result: {result}")
        print()

if __name__ == '__main__':
    main()
