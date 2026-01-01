#!/usr/bin/env python3
"""
Send getheaders to local node using EXACTLY the same parameters as the Swift app
This will help identify if the issue is with the payload or something else
"""
import socket
import struct
import time

NETWORK_MAGIC = b'\x24\xe9\x27\x64'

def double_sha256(data):
    return __import__('hashlib').sha256(__import__('hashlib').sha256(data).digest()).digest()

def create_message(command, payload=b''):
    command_bytes = command.encode('ascii')[:12]
    command_bytes = command_bytes + b'\x00' * (12 - len(command_bytes))
    length = struct.pack('<I', len(payload))
    checksum = double_sha256(payload)[:4]
    message = NETWORK_MAGIC + command_bytes + length + checksum + payload
    return message

def connect_and_handshake():
    """Connect and complete handshake"""
    print("📡 Connecting to 127.0.0.1:8033...")
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(10)
    sock.connect(('127.0.0.1', 8033))
    print("✅ Connected")

    # Send version
    version = struct.pack('<i', 170012)  # Same as Swift
    services = struct.pack('<Q', 0)
    timestamp = struct.pack('<q', int(time.time()))

    addr_recv = struct.pack('<Q', 0)  # services
    addr_recv += b'\x00' * 10
    addr_recv += b'\xff\xff'
    addr_recv += socket.inet_pton(socket.AF_INET, '127.0.0.1')
    addr_recv += struct.pack('>H', 8033)

    addr_from = addr_recv
    nonce = struct.pack('<Q', 0)
    user_agent = b'/ZipherX-Test:1.0/'
    start_height = struct.pack('<i', 2962798)
    relay = struct.pack('B', 0)

    payload = version + services + timestamp + addr_recv + addr_from + nonce
    payload += struct.pack('B', len(user_agent)) + user_agent + start_height + relay

    message = create_message('version', payload)
    sock.sendall(message)
    print("📤 Version sent")

    # Receive version, send verack
    header = sock.recv(24)
    cmd_len = header[4:16].rstrip(b'\x00').__len__()
    payload_len = struct.unpack('<I', header[16:20])[0]
    payload = sock.recv(payload_len)

    # Handle sendaddrv2
    header = sock.recv(24)
    if b'sendaddrv2' in header:
        print("   Got sendaddrv2")

    message = create_message('verack')
    sock.sendall(message)
    print("📤 Verack sent")

    # Receive verack
    header = sock.recv(24)
    payload_len = struct.unpack('<I', header[16:20])[0]
    if payload_len == 0:
        print("✅ Handshake complete")
        return sock

    raise Exception("Handshake failed")

def send_getheaders_swift_format(sock, start_height):
    """Send getheaders exactly as Swift does"""
    print(f"\n📤 Sending getheaders (Swift format, start_height={start_height})...")

    # Use bytearray for mutable operations, then convert to bytes
    payload = bytearray()

    # Protocol version (170012 = BIP155 support)
    version = struct.pack('<i', 170012)
    payload.extend(version)

    # Number of block locator hashes (varint - use 1 for simplicity)
    hash_count = 1
    payload.append(hash_count)  # For < 0xFD, just 1 byte

    # Locator height = startHeight - 1
    locator_height = start_height - 1 if start_height > 0 else 0
    print(f"   Locator height: {locator_height}")

    # Use checkpoint hash (same as Swift would use)
    # Checkpoint at 2962638
    checkpoint_hex = '000006ef36df7868360159dd79ce43665569229485abace3864b2bdd98d7202e'
    locator_hash = bytes.fromhex(checkpoint_hex)[::-1]  # Reverse to wire format
    payload.extend(locator_hash)

    print(f"   Locator hash: {checkpoint_hex}")

    # Stop hash (zero = get maximum headers)
    payload.extend(b'\x00' * 32)

    print(f"   Payload size: {len(payload)} bytes")
    print(f"   Payload hex: {payload.hex()}")

    # Build and send message
    message = create_message('getheaders', bytes(payload))
    sock.sendall(message)
    print("   getheaders sent")

    return payload

def wait_for_response(sock, timeout=10):
    """Wait for headers response"""
    print("\n⏳ Waiting for response...")

    start = time.time()
    while time.time() - start < timeout:
        sock.settimeout(1)
        try:
            # Read header
            header = sock.recv(24)
            if len(header) < 24:
                continue

            # Parse
            magic = header[:4]
            if magic != NETWORK_MAGIC:
                print(f"   Bad magic: {magic.hex()}")
                continue

            command = header[4:16].rstrip(b'\x00').decode('ascii', errors='ignore')
            length = struct.unpack('<I', header[16:20])[0]
            checksum = header[20:24]

            # Read payload
            payload = b''
            while len(payload) < length:
                chunk = sock.recv(min(4096, length - len(payload)))
                if not chunk:
                    break
                payload += chunk

            elapsed = time.time() - start
            print(f"   Received: {command} ({len(payload)} bytes) after {elapsed:.3f}s")

            if command == 'headers':
                # Parse count
                count = struct.unpack('<B', payload[0:1])[0]
                print(f"   Headers count: {count}")
                return count

            elif command == 'reject':
                print(f"   ⛔ REJECT!")
                print(f"   Payload: {payload.hex()}")

                # Try to parse
                try:
                    null_idx = payload.index(b'\x00')
                    rejected_cmd = payload[:null_idx].decode('ascii')
                    offset = null_idx + 1
                    code = payload[offset]
                    offset += 1
                    null_idx2 = payload[offset:].index(b'\x00')
                    reason = payload[offset:offset+null_idx2].decode('ascii')
                    print(f"   Command: {rejected_cmd}, Code: {code}, Reason: {reason}")
                except:
                    pass

                return None

            elif command == 'ping':
                print("   Got ping, sending pong")
                pong = create_message('pong', payload)
                sock.sendall(pong)

        except socket.timeout:
            continue
        except Exception as e:
            print(f"   Error: {e}")
            break

    print(f"   ❌ Timeout after {timeout}s")
    return None

def main():
    print("=" * 60)
    print("Test getheaders (Swift-compatible format)")
    print("=" * 60)

    try:
        sock = connect_and_handshake()

        # Test 1: Start at 2962799 (same as Swift app)
        count = send_getheaders_swift_format(sock, 2962799)
        result = wait_for_response(sock)

        if result and result > 0:
            print(f"\n✅ SUCCESS: Got {result} headers")
            print("   The getheaders format IS correct!")
            print("   The issue must be elsewhere in Swift code")
        else:
            print(f"\n❌ FAILED: No headers received")

    except Exception as e:
        print(f"\n❌ Exception: {e}")
        import traceback
        traceback.print_exc()
    finally:
        try:
            sock.close()
        except:
            pass

if __name__ == '__main__':
    main()
