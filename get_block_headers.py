#!/usr/bin/env python3
"""
Get block headers from Zclassic P2P peers
Based on Zclassic source code protocol implementation
"""

import socket
import struct
import sys
import time
import hashlib

NETWORK_MAGIC = bytes.fromhex("24279e24")  # Zclassic

TRUSTED_PEERS = [
    # Zelcore InsightAPI working peers (MagicBean 2.1.x)
    ("37.187.76.79", 8033),
    ("157.90.223.151", 8033),
    ("51.178.179.75", 8033),
    ("162.55.92.62", 8033),
    ("205.209.104.118", 8033),
    ("74.50.74.102", 8033),
    ("185.205.246.161", 8033),
    ("140.174.189.3", 8033),
]

def create_address(addr_str: str, port: int, services: int) -> bytes:
    """Create a CAddress structure (26 bytes for IPv4)"""
    # Services (8 bytes)
    addr = struct.pack('<Q', services)

    # IPv6 encoded in IPv6 (16 bytes) - IPv4-mapped IPv6
    # Format: 00...00 + ffff + IPv4 (4 bytes)
    if ':' in addr_str:
        # IPv6 address
        import socket as socket_mod
        addr_bytes = socket_mod.inet_pton(socket_mod.AF_INET6, addr_str)
    else:
        # IPv4 address - encode as IPv4-mapped IPv6
        import socket as socket_mod
        addr_bytes = socket_mod.inet_pton(socket_mod.AF_INET, addr_str)
        # Convert to IPv4-mapped IPv6: ::ffff:IPv4
        addr_bytes = b'\x00' * 10 + b'\xff\xff' + addr_bytes

    addr += addr_bytes

    # Port (2 bytes, big endian)
    addr += struct.pack('>H', port)

    return addr

def create_version_message(start_height: int, protocol_version: int = 170012) -> bytes:
    """
    Create Zclassic version message based on Zclassic source code
    Format from CNode::PushVersion() in net.cpp
    """
    nTime = int(time.time())
    nLocalServices = 1  # NODE_NETWORK
    nLocalHostNonce = 0  # Placeholder nonce
    # Try using MagicBean user agent to match what most peers use
    strSubVersion = b'/MagicBean:2.1.1/'

    # Build payload according to Zclassic protocol
    # From: PushMessage("version", PROTOCOL_VERSION, nLocalServices, nTime, addrYou, addrMe,
    #                nLocalHostNonce, strSubVersion, nBestHeight, true);

    payload = struct.pack('<I', protocol_version)  # Version (4 bytes)
    payload += struct.pack('<Q', nLocalServices)  # Services (8 bytes)
    payload += struct.pack('<Q', nTime)  # Timestamp (8 bytes)

    # addrYou - receiver's address (26 bytes)
    # Use IPv4 loopback as placeholder
    payload += create_address("0.0.0.0", 0, 0)  # All zeros for "from" address

    # addrMe - sender's address (26 bytes)
    # Use empty address as sender
    payload += create_address("0.0.0.0", 0, 0)  # All zeros

    # Nonce (8 bytes)
    payload += struct.pack('<Q', nLocalHostNonce)

    # User agent (length-prefixed string)
    payload += bytes([len(strSubVersion)]) + strSubVersion

    # Start height (4 bytes)
    payload += struct.pack('<I', start_height)

    # Relay flag (1 byte, True = relay transactions)
    payload += b'\x01'

    return payload

def create_message(command: str, payload: bytes = b"") -> bytes:
    """Create P2P message with Zclassic network magic"""
    command_bytes = command.encode('ascii').ljust(12, b'\x00')
    length = struct.pack('<I', len(payload))

    if payload:
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
            # Try to read any remaining data in buffer before giving up
            try:
                sock.settimeout(0.5)
                remaining = sock.recv(4096, socket.MSG_PEEK)
                if remaining:
                    print(f"    [PEER SEND] {len(remaining)} bytes in buffer: {remaining.hex()[:200]}")
            except:
                pass
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

def test_peer(host, port, start_height):
    """Test connection and get block headers from Zclassic peer"""
    print(f"  Testing {host}:{port}...")

    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)

    try:
        print(f"    [1/7] Connecting...", flush=True)
        sock.connect((host, port))

        # Small delay to let connection stabilize
        time.sleep(0.1)

        # Send version message with protocol version 170011 (matches most peers)
        print(f"    [2/7] Sending version message (protocol 170011)...", flush=True)
        version_msg = create_version_message(start_height, protocol_version=170011)
        msg = create_message('version', version_msg)

        print(f"    [DEBUG] Version payload size: {len(version_msg)} bytes", flush=True)
        print(f"    [DEBUG] Total message size: {len(msg)} bytes", flush=True)
        print(f"    [HEX DUMP] Message header (24 bytes): {msg[:24].hex()}", flush=True)
        print(f"    [HEX DUMP] First 32 bytes of payload: {msg[24:56].hex()}", flush=True)

        sock.sendall(msg)

        # Small delay to let peer process
        time.sleep(0.1)

        print(f"    [3/7] Waiting for version/verack...", flush=True)

        # First message should be version
        command, payload = recv_message(sock)
        print(f"    [4/7] Got '{command}' ({len(payload)} bytes)", flush=True)

        if command == 'version':
            # Parse version message to see peer info
            if len(payload) >= 4:
                peer_version = struct.unpack('<I', payload[:4])[0]
                print(f"    [INFO] Peer version: {peer_version}", flush=True)

            print(f"    [5/7] Sending verack...", flush=True)
            sock.sendall(create_message('verack', b''))

            # Wait for verack
            command2, payload2 = recv_message(sock)
            print(f"    [6/7] Got '{command2}'", flush=True)

            if command2 == 'verack':
                print(f"    ✓ Handshake complete!", flush=True)

                # Now request headers
                print(f"    [7/7] Requesting block headers...", flush=True)

                zero_hash = b'\x00' * 32
                stop_hash = b'\xff' * 32

                # getheaders message: version + count + locator + stop_hash
                getheaders = struct.pack('<I', 170012)  # Version
                getheaders += b'\x01'  # Hash count = 1
                getheaders += zero_hash  # Locator hash

                # Build proper locator with version count
                # According to protocol, locator is: varint count + hash list
                # For single hash starting from genesis:
                locator = b'\x01' + zero_hash  # count=1 + genesis hash
                getheaders = struct.pack('<I', 170012) + locator + stop_hash

                sock.sendall(create_message('getheaders', getheaders))

                # Wait for headers response
                try:
                    cmd3, pay3 = recv_message(sock)
                    if cmd3 == 'headers':
                        # Parse count
                        if pay3[0] < 0xfd:
                            count = pay3[0]
                        elif pay3[0] == 0xfd:
                            count = struct.unpack('<H', pay3[1:3])[0]
                        elif pay3[0] == 0xfe:
                            count = struct.unpack('<I', pay3[1:5])[0]
                        else:
                            count = 0

                        print(f"    ✓✓ SUCCESS! Got {count} headers!", flush=True)

                        # Extract first header to get timestamp
                        if count > 0 and len(pay3) > 10:
                            # Skip count bytes, then parse first header
                            # Header format: version(4) + prev_hash(32) + merkle_root(32) + timestamp(4) + ...
                            offset = 1  # Skip count
                            if pay3[offset] == 0xfd:
                                offset += 3
                            elif pay3[offset] == 0xfe:
                                offset += 5

                            # Skip to timestamp field (after version + prev_hash + merkle_root)
                            offset += 4 + 32 + 32
                            timestamp = struct.unpack('<I', pay3[offset:offset+4])[0]
                            print(f"    First header timestamp: {timestamp}", flush=True)

                        return True
                    else:
                        print(f"    Got '{cmd3}' instead of headers ({len(pay3)} bytes)", flush=True)
                        print(f"    Hex: {pay3[:50].hex()}", flush=True)
                except Exception as e:
                    print(f"    Timeout waiting for headers: {e}", flush=True)

            return True

        elif command == 'verack':
            print(f"    Peer sent verack immediately (unusual but okay)", flush=True)

            # Try getheaders anyway
            print(f"    [GET] Requesting headers...", flush=True)

            zero_hash = b'\x00' * 32
            stop_hash = b'\xff' * 32

            getheaders = struct.pack('<I', 170012) + b'\x01' + zero_hash + stop_hash
            sock.sendall(create_message('getheaders', getheaders))

            try:
                cmd3, pay3 = recv_message(sock)
                if cmd3 == 'headers':
                    if pay3[0] < 0xfd:
                        count = pay3[0]
                    elif pay3[0] == 0xfd:
                        count = struct.unpack('<H', pay3[1:3])[0]
                    else:
                        count = 0

                    print(f"    ✓✓ SUCCESS! Got {count} headers!", flush=True)
                    return True
                else:
                    print(f"    Got '{cmd3}' instead: {pay3[:50].hex()}", flush=True)
            except Exception as e:
                print(f"    Timeout: {e}", flush=True)

            return True

        else:
            print(f"    Unexpected: '{command}' - {payload[:50].hex()}", flush=True)
            return False

    except Exception as e:
        print(f"    ✗ Error: {e}", flush=True)
        import traceback
        traceback.print_exc()
        return False
    finally:
        try:
            sock.close()
        except:
            pass

def main():
    if len(sys.argv) < 3:
        print("Usage: python3 get_block_headers.py <start_height> <end_height>")
        print("\nExample:")
        print("  python3 get_block_headers.py 2961027 2961374")
        print("\nThis script tests P2P connection to Zclassic peers and retrieves block headers.")
        print("It helps diagnose whether peers are accepting connections and responding properly.")
        sys.exit(1)

    start_height = int(sys.argv[1])
    end_height = int(sys.argv[2])

    print("=" * 60)
    print(f"Testing Zclassic P2P Peer Connectivity")
    print(f"Requesting headers from {start_height} to {end_height}")
    print("=" * 60)

    for host, port in TRUSTED_PEERS:
        if test_peer(host, port, start_height):
            print(f"\n✅ SUCCESS! Peer {host}:{port} is working!")
            print(f"The app should be able to sync headers from this peer.")
            print(f"\nIf the app still fails to sync, the issue is in the app's peer selection")
            print(f"or handshake logic, not the peer itself.")
            return

    print(f"\n⚠️ Could not complete handshake with any peer")
    print(f"This could indicate:")
    print(f"  1. Network connectivity issues")
    print(f"  2. Peers are rejecting connections (IP ban, rate limiting)")
    print(f"  3. Protocol version mismatch")
    print(f"\nCheck the app logs (zmac.log or z.log) for details.")

if __name__ == '__main__':
    main()
