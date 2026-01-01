#!/usr/bin/env python3
"""
Test script to verify local zclassic node responds to P2P getheaders request
This isolates whether the issue is in the app code or the node itself
"""
import socket
import struct
import time
import hashlib

# Zclassic mainnet magic bytes
NETWORK_MAGIC = b'\x24\xe9\x27\x64'

def double_sha256(data):
    """Double SHA256 hash"""
    return hashlib.sha256(hashlib.sha256(data).digest()).digest()

def create_message(command, payload=b''):
    """Create a P2P message with command and payload"""
    # Command is 12 bytes, null-padded
    command_bytes = command.encode('ascii')[:12]
    command_bytes = command_bytes + b'\x00' * (12 - len(command_bytes))

    # Length is 4 bytes little-endian
    length = struct.pack('<I', len(payload))

    # Checksum is first 4 bytes of double SHA256 of payload
    checksum = double_sha256(payload)[:4]

    # Message = magic + command + length + checksum + payload
    message = NETWORK_MAGIC + command_bytes + length + checksum + payload
    return message

def parse_version_response(data):
    """Parse version message response"""
    if len(data) < 4:
        return None

    version = struct.unpack('<i', data[:4])[0]
    print(f"   Version: {version}")

    # Extract user agent (skip version, services, timestamp, addr_recv, addr_from, nonce)
    # Skip to user_agent string (variable length)
    # Format: version(4) + services(8) + timestamp(8) + addr_recv(26) + addr_from(26) + nonce(8) = 80 bytes
    if len(data) >= 80:
        user_agent_len = struct.unpack('<B', data[80:81])[0]
        if user_agent_len > 0 and len(data) >= 81 + user_agent_len:
            user_agent = data[81:81+user_agent_len].decode('utf-8', errors='ignore')
            print(f"   User Agent: {user_agent}")

    return version

def connect_to_localnode():
    """Connect to local zclassic node"""
    host = '127.0.0.1'
    port = 8033

    print(f"📡 Connecting to {host}:{port}...")
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(10)  # 10 second timeout
    sock.connect((host, port))
    print(f"✅ Connected to local node")
    return sock

def send_version(sock):
    """Send version message"""
    print("📤 Sending version message...")

    # Build version payload
    version = 170012  # Support BIP155
    services = 0
    timestamp = int(time.time())

    # Addr_recv (network receiver) - IPv4 localhost
    addr_recv = struct.pack('<Q', 0)  # services
    addr_recv += b'\x00' * 10  # IPv6 placeholder
    addr_recv += b'\xff\xff'  # IPv4 marker
    addr_recv += socket.inet_pton(socket.AF_INET, '127.0.0.1')  # IPv4
    addr_recv += struct.pack('>H', 8033)  # port big-endian

    # Addr_from (network sender) - same
    addr_from = addr_recv

    # Nonce
    nonce = 0

    # User agent
    user_agent = b'/ZipherX-Test:1.0/'

    # Start height
    start_height = 2962798

    # Relay
    relay = 0

    payload = struct.pack('<i', version)
    payload += struct.pack('<Q', services)
    payload += struct.pack('<q', timestamp)
    payload += addr_recv
    payload += addr_from
    payload += struct.pack('<Q', nonce)
    payload += struct.pack('B', len(user_agent))
    payload += user_agent
    payload += struct.pack('<i', start_height)
    payload += struct.pack('B', relay)

    message = create_message('version', payload)
    sock.sendall(message)
    print("   Version message sent")

def send_verack(sock):
    """Send verack message"""
    print("📤 Sending verack...")
    message = create_message('verack')
    sock.sendall(message)
    print("   Verack sent")

def receive_message(sock):
    """Receive a complete P2P message"""
    # Read header (24 bytes)
    header = b''
    while len(header) < 24:
        chunk = sock.recv(24 - len(header))
        if not chunk:
            raise Exception("Connection closed while reading header")
        header += chunk

    # Parse header
    magic = header[:4]
    if magic != NETWORK_MAGIC:
        raise Exception(f"Invalid magic bytes: {magic.hex()}")

    command = header[4:16].rstrip(b'\x00').decode('ascii', errors='ignore')
    length = struct.unpack('<I', header[16:20])[0]
    checksum = header[20:24]

    # Read payload
    payload = b''
    while len(payload) < length:
        chunk = sock.recv(min(4096, length - len(payload)))
        if not chunk:
            raise Exception("Connection closed while reading payload")
        payload += chunk

    return command, payload

def wait_for_verack(sock):
    """Wait for verack message (handles sendaddrv2)"""
    print("⏳ Waiting for verack...")
    try:
        command, payload = receive_message(sock)
        print(f"   Received: {command} ({len(payload)} bytes)")

        if command == 'version':
            print("   Got version, parsing...")
            parse_version_response(payload)

            # Wait for next message (might be sendaddrv2 or verack)
            print("⏳ Waiting for next message...")
            command, payload = receive_message(sock)
            print(f"   Received: {command} ({len(payload)} bytes)")

            # If sendaddrv2, send verack and wait for their verack
            if command == 'sendaddrv2':
                print("   Got sendaddrv2 (BIP155 support)")
                send_verack(sock)

                print("⏳ Waiting for verack...")
                command, payload = receive_message(sock)
                print(f"   Received: {command} ({len(payload)} bytes)")

        return command == 'verack'
    except Exception as e:
        print(f"❌ Error: {e}")
        return False

def send_getheaders(sock, locator_height):
    """Send getheaders request"""
    print(f"📤 Sending getheaders request (locator at height {locator_height})...")

    # Build getheaders payload
    version = 170012
    hash_count = 1  # One locator hash

    # For getheaders starting at height X, we need the block hash at height X-1
    # This requests headers starting from height X
    locator_hash_height = locator_height - 1 if locator_height > 0 else 0

    # Use checkpoint hash for locator (reversed to wire format)
    # Known checkpoint at 2926122
    checkpoint_hashes = {
        2926122: '0000016061285387595f9453c2e3d33f99120aa67acd256fd05a79491528d5cd',
        2962638: '000006ef36df7868360159dd79ce43665569229485abace3864b2bdd98d7202e',
    }

    # Find closest checkpoint at or below locator height
    checkpoint_height = max(h for h in checkpoint_hashes.keys() if h <= locator_hash_height)
    checkpoint_hex = checkpoint_hashes[checkpoint_height]

    # Convert hex to bytes and reverse for wire format
    locator_hash = bytes.fromhex(checkpoint_hex)[::-1]

    print(f"   Using checkpoint at height {checkpoint_height} as locator")
    print(f"   Locator hash: {checkpoint_hex}")

    # Build payload
    payload = struct.pack('<i', version)

    # FIX: hash_count is a varint (compactSize), not just 1 byte
    # For values < 0xFD, it's just 1 byte
    payload += struct.pack('B', hash_count)

    # Locator hash(es)
    payload += locator_hash

    # FIX: Stop hash is 32 bytes (all zeros = no stop)
    payload += b'\x00' * 32

    message = create_message('getheaders', payload)
    sock.sendall(message)
    print(f"   getheaders sent (payload size: {len(payload)} bytes)")

def receive_headers(sock):
    """Receive headers response"""
    print("⏳ Waiting for headers response...")

    start_time = time.time()
    timeout = 10  # 10 second timeout

    while True:
        # Check timeout
        if time.time() - start_time > timeout:
            print(f"❌ Timeout waiting for headers response ({timeout}s)")
            return None

        # Set socket timeout for recv
        sock.settimeout(1)

        try:
            command, payload = receive_message(sock)
            elapsed = time.time() - start_time
            print(f"   Received: {command} ({len(payload)} bytes) after {elapsed:.2f}s")

            if command == 'headers':
                # Parse headers count
                count = struct.unpack('<B', payload[0:1])[0]
                print(f"   Headers count: {count}")

                # Each header is at least 80 bytes (without solution)
                # Zclassic post-Bubbles uses Equihash(192,7) with 400-byte solutions
                # Total header = 80 + 1 (varint) + 400 = 481 bytes

                offset = 1
                for i in range(min(count, 5)):  # Show first 5 headers
                    if offset + 80 > len(payload):
                        break

                    # Parse header (80 bytes)
                    header_data = payload[offset:offset+80]

                    # Extract version, prev block hash, merkle root, timestamp, bits, nonce
                    version = struct.unpack('<i', header_data[0:4])[0]
                    prev_hash = header_data[4:36][::-1].hex()
                    merkle_root = header_data[36:68][::-1].hex()
                    timestamp = struct.unpack('<I', header_data[68:72])[0]
                    bits = struct.unpack('<I', header_data[72:76])[0]
                    nonce = header_data[76:80]

                    from datetime import datetime
                    dt = datetime.fromtimestamp(timestamp)

                    print(f"   Header #{i+1}:")
                    print(f"      Version: {version}")
                    print(f"      Timestamp: {timestamp} ({dt})")
                    print(f"      Prev hash: {prev_hash[:16]}...")
                    print(f"      Merkle root: {merkle_root[:16]}...")

                    # Read solution length (varint)
                    varint_size = payload[offset + 80]
                    solution_size = varint_size & 0x7F  # Remove continuation bit

                    # Move to next header
                    offset += 81 + solution_size

                print(f"✅ Successfully received {count} headers!")
                return count

            elif command == 'ping':
                print("   Got ping, sending pong...")
                pong = create_message('pong', payload)
                sock.sendall(pong)

            else:
                print(f"   Got unexpected command: {command}")
                if command == 'reject':
                    # Parse reject message
                    # Format: command(varstring) + code(uint8) + reason(varstring) + data(optional)
                    try:
                        # Command (null-terminated)
                        cmd_end = payload.index(b'\x00')
                        rejected_cmd = payload[:cmd_end].decode('ascii')
                        offset = cmd_end + 1

                        # Code
                        code = struct.unpack('B', payload[offset:offset+1])[0]
                        offset += 1

                        # Reason
                        reason_end = payload[offset:].index(b'\x00')
                        reason = payload[offset:offset+reason_end].decode('ascii')

                        print(f"   ⛔ REJECT message:")
                        print(f"      Rejected command: {rejected_cmd}")
                        print(f"      Code: {code}")
                        print(f"      Reason: {reason}")

                        # Reject codes:
                        # 0x01 = malformed
                        # 0x10 = invalid
                        # 0x11 = obsolete
                        # 0x12 = duplicate
                        # 0x40 = non-standard
                        # 0x41 = dust
                        # 0x42 - insufficient fee
                        # 0x43 = checkpoint

                        code_names = {
                            0x01: "MALFORMED",
                            0x10: "INVALID",
                            0x11: "OBSOLETE",
                            0x12: "DUPLICATE",
                            0x40: "NON-STANDARD",
                            0x41: "DUST",
                            0x42: "INSUFFICIENT_FEE",
                            0x43: "CHECKPOINT"
                        }
                        code_name = code_names.get(code, f"UNKNOWN({code})")
                        print(f"      Code meaning: {code_name}")

                    except Exception as e:
                        print(f"   (Failed to parse reject message: {e})")
                        print(f"   Raw payload: {payload.hex()}")

        except socket.timeout:
            continue
        except Exception as e:
            print(f"❌ Error receiving: {e}")
            return None

def main():
    print("=" * 60)
    print("ZipherX Local Node P2P Test")
    print("=" * 60)

    try:
        # Connect
        sock = connect_to_localnode()

        # Version handshake
        send_version(sock)

        # Wait for verack (this handles the full handshake including sendaddrv2)
        if not wait_for_verack(sock):
            print("❌ Failed to complete handshake")
            return

        print("✅ Handshake complete!")
        print()

        # Test getheaders
        locator_height = 2962799  # Height after bundled headers
        send_getheaders(sock, locator_height)

        # Wait for headers response
        headers_count = receive_headers(sock)

        if headers_count is not None and headers_count > 0:
            print(f"\n✅ SUCCESS: Local node responded with {headers_count} headers")
            print("   This means the node IS working correctly!")
            print("   The issue must be in the app's Swift code.")
        else:
            print("\n❌ FAILED: Local node did not respond with headers")
            print("   This suggests a node issue, not app code.")

    except Exception as e:
        print(f"\n❌ Exception: {e}")
        import traceback
        traceback.print_exc()

    finally:
        try:
            sock.close()
            print("\n📡 Connection closed")
        except:
            pass

if __name__ == '__main__':
    main()
