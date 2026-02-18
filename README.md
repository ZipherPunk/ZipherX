# ZipherX

**Privacy-focused, non-custodial cryptocurrency wallet for Zclassic (ZCL)**

ZipherX provides full-node-level security through direct P2P networking — without running a full node. Your keys never leave your device. All network traffic is routed through Tor for maximum privacy.

---

## Features

- **Shielded Transactions** — Sapling zk-SNARK privacy (Groth16 proofs)
- **Non-Custodial** — You hold your keys. No server. No middleman.
- **P2P Networking** — Connects directly to the Zclassic blockchain via peer-to-peer protocol
- **Tor Integration** — All connections routed through embedded Tor (Arti) for network privacy
- **Encrypted Chat** — End-to-end encrypted messaging over Tor hidden services
- **Biometric Security** — Face ID / Touch ID protection for wallet access and transactions
- **Cross-Platform** — Native macOS (Apple Silicon + Intel) and iOS (iPhone + iPad)
- **Full Node Mode** — Optional: connect to your own Zclassic full node via RPC
- **Fast Sync** — Boost files enable wallet sync in under 30 seconds
- **SQLCipher** — Database encrypted at rest with 256-bit AES

---

## Prerequisites

### macOS

| Requirement | Version |
|-------------|---------|
| macOS | 13.0 (Ventura) or later |
| Xcode | 15.0 or later |
| Rust | 1.75+ (for FFI compilation) |
| Command Line Tools | `xcode-select --install` |

### iOS

| Requirement | Version |
|-------------|---------|
| iOS | 15.0 or later |
| Xcode | 15.0 or later |
| Rust (cross-compile) | 1.75+ with `aarch64-apple-ios` target |
| Apple Developer Account | Required for device deployment |

### Rust Toolchain

```bash
# Install Rust
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh

# Add iOS target (for iOS builds)
rustup target add aarch64-apple-ios
rustup target add aarch64-apple-ios-sim

# Add macOS target (if cross-compiling)
rustup target add aarch64-apple-darwin
rustup target add x86_64-apple-darwin
```

### Sapling Parameters

ZipherX requires Sapling cryptographic parameters for zk-SNARK proof generation. These are downloaded automatically on first launch, or you can pre-download them:

| File | Size | Purpose |
|------|------|---------|
| `sapling-spend.params` | ~47 MB | Spend proof generation |
| `sapling-output.params` | ~3.5 MB | Output proof generation |

Parameters are stored in `~/Library/Application Support/ZipherX/SaplingParams/`.

---

## Installation

### Build from Source (macOS)

```bash
# 1. Clone the repository
git clone https://github.com/AurumWallet/ZipherX.git
cd ZipherX

# 2. Build the Rust FFI library
cd Libraries/zipherx-ffi
cargo build --release --target aarch64-apple-darwin
cd ../..

# 3. Open in Xcode
open ZipherX.xcodeproj

# 4. Select the "ZipherX" scheme and your target (My Mac)

# 5. Build and Run (Cmd+R)
```

### Build from Source (iOS)

```bash
# 1. Clone the repository
git clone https://github.com/AurumWallet/ZipherX.git
cd ZipherX

# 2. Build the Rust FFI library for iOS
cd Libraries/zipherx-ffi
cargo build --release --target aarch64-apple-ios
cd ../..

# 3. Open in Xcode
open ZipherX.xcodeproj

# 4. Select the "ZipherX" scheme and your iOS device

# 5. Configure signing (Signing & Capabilities → select your team)

# 6. Build and Run (Cmd+R)
```

### Build Notes

- **SQLCipher**: Pre-built xcframework is included in `Libraries/SQLCipher.xcframework/`
- **ZipherXFFI**: Pre-built xcframework headers are included. To rebuild from source, use the build scripts in `Libraries/zipherx-ffi/`
- **Boost Files**: Downloaded automatically on first launch from the ZipherX CDN. Enables fast sync (~30 seconds vs ~5 minutes for full scan)

---

## User Guide

### First Launch

1. **Create or Import Wallet**
   - **New Wallet**: Generates a new spending key secured by the device's Secure Enclave
   - **Import Wallet**: Enter an existing spending key or seed phrase to restore your wallet

2. **Initial Sync**
   - The app downloads a boost file (~1 GB) for fast synchronization
   - Once synced, the wallet displays your shielded balance
   - Subsequent launches sync incrementally (typically under 3 seconds)

### Sending ZCL

1. Tap **Send** from the main screen
2. Enter the recipient's shielded address (`zs1...`) or scan a QR code
3. Enter the amount in ZCL
4. Optionally add an encrypted memo (up to 512 bytes)
5. Review the transaction details and fee (default: 0.0001 ZCL)
6. Authenticate with Face ID / Touch ID
7. The transaction is built locally (Groth16 proof, ~2-4 seconds) and broadcast to the network

### Receiving ZCL

1. Tap **Receive** from the main screen
2. Share your shielded address or QR code with the sender
3. Incoming transactions appear after 1 block confirmation (~150 seconds)

### Encrypted Chat

ZipherX includes peer-to-peer encrypted messaging over Tor:

1. Go to **Chat** from the main menu
2. **Enable Tor** — Required for chat (all messages route through Tor hidden services)
3. **Add Contact** — Share your onion address with the other party
4. **Send Messages** — End-to-end encrypted with Curve25519 key agreement
5. **Send Payment Requests** — Request ZCL directly in chat
6. **Profile Picture** — Set in Chat Settings (iOS: from Photos, macOS: from file)
7. **Block Contacts** — Right-click (macOS) or long-press (iOS) a contact to block

### Full Node Mode

For users running their own Zclassic full node:

1. Go to **Settings > Full Node**
2. Enter your node's RPC host, port, username, and password
3. Toggle **Full Node Mode** on
4. The app connects to your node for enhanced security and faster queries

### Security Settings

- **Biometric Lock** — Enable Face ID / Touch ID to protect wallet access
- **Lock Timer** — Auto-lock after inactivity (30s, 1m, 5m, 15m, or Never)
- **PIN Backup** — Set a PIN as fallback when biometrics are unavailable

### Backup & Recovery

Your spending key is the master secret for your wallet. **If you lose it, your funds are unrecoverable.**

1. Go to **Settings > Export Keys**
2. Authenticate with biometrics
3. Copy or write down your spending key
4. Store it securely offline (never screenshot, never share)

### Network Status

The status bar shows:
- **Peers**: Number of connected P2P peers (3+ recommended)
- **Height**: Current blockchain height vs. your synced height
- **Tor**: Connection status (required for chat)

---

## Architecture

```
SwiftUI / AppKit UI
    |
Swift Core (WalletManager, NetworkManager, FilterScanner)
    |
Rust FFI (Sapling crypto, commitment tree, Groth16 prover)
    |
Storage (SQLCipher encrypted database, HeaderStore)
    |
Network (P2P protocol over Tor, DNS seed discovery)
```

### Key Technologies

| Component | Technology |
|-----------|-----------|
| UI | SwiftUI (iOS + macOS) |
| Crypto | Sapling / Groth16 zk-SNARKs (Rust FFI) |
| Database | SQLCipher (256-bit AES) |
| Networking | P2P Bitcoin-based protocol |
| Privacy | Tor (embedded Arti client) |
| Key Storage | Secure Enclave (iOS/macOS) |
| Chat Encryption | Curve25519 + ChaCha20-Poly1305 |

---

## Network Constants

| Parameter | Value |
|-----------|-------|
| Network | Zclassic Mainnet |
| Protocol Version | 170009 |
| Default Port | 8033 |
| Sapling Activation | Block 476,969 |
| Equihash Parameters | (192, 7) |
| Default Fee | 10,000 zatoshis (0.0001 ZCL) |

---

## License

MIT License — See [LICENSE](LICENSE) for details.

---

## Disclaimer

ZipherX is provided as-is. Cryptocurrency transactions are irreversible. Always verify addresses before sending. The developers are not responsible for lost funds due to user error, software bugs, or network issues. Use at your own risk.

---

Built by [Zipherpunk](https://zipherpunk.com)

*"Privacy is necessary for an open society in the electronic age." — A Cypherpunk's Manifesto*
