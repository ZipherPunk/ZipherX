# ZipherX

> **IMPORTANT LEGAL DISCLAIMER**
>
> THIS SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE, TITLE, AND NON-INFRINGEMENT. THE ENTIRE RISK AS TO THE QUALITY, PERFORMANCE, ACCURACY, AND RELIABILITY OF THIS SOFTWARE REMAINS WITH YOU.
>
> **NO LIABILITY FOR LOSS OF FUNDS.** ZipherX is experimental, open-source software. The authors, contributors, and maintainers of this project shall NOT be held liable, under any circumstances, for any loss of funds, loss of cryptocurrency, loss of data, financial damages, or any other damages whatsoever (including but not limited to direct, indirect, incidental, special, consequential, or exemplary damages) arising out of or in connection with the use, misuse, or inability to use this software, even if advised of the possibility of such damages.
>
> **YOU ARE SOLELY RESPONSIBLE** for securing your private keys, spending keys, seed phrases, and wallet backups. If you lose your keys, your funds are permanently and irreversibly lost. No one — including the developers — can recover them.
>
> **CRYPTOCURRENCY TRANSACTIONS ARE IRREVERSIBLE.** Once a transaction is broadcast to the network, it cannot be undone, reversed, or refunded. Always verify recipient addresses and amounts before sending.
>
> **THIS IS NOT FINANCIAL ADVICE.** This software does not constitute financial, investment, tax, or legal advice. Consult a qualified professional before making any financial decisions involving cryptocurrency.
>
> **REGULATORY COMPLIANCE IS YOUR RESPONSIBILITY.** Cryptocurrency regulations vary by jurisdiction. It is your sole responsibility to ensure that your use of this software complies with all applicable local, state, national, and international laws and regulations.
>
> **NO GUARANTEE OF SECURITY.** While ZipherX implements industry-standard cryptographic protocols (zk-SNARKs, Groth16, Curve25519, AES-256), no software is guaranteed to be free of vulnerabilities. Use at your own risk.
>
> **BETA SOFTWARE.** This software is under active development and may contain bugs, errors, or incomplete features. Do not use this software with funds you cannot afford to lose.
>
> **BACKUP YOUR WALLET BEFORE INSTALLATION.** If you are running an existing Zclassic full node or any other wallet software, you MUST back up your wallet files, private keys, and spending keys BEFORE installing or using ZipherX. ZipherX's Full Node mode connects to your local node and software bugs could potentially overwrite, corrupt, or delete existing wallet data. The developers accept NO responsibility for loss of funds or data resulting from failure to back up. This applies to both P2P mode and Full Node mode. **Always maintain independent, offline backups of your keys and wallet files.**
>
> By downloading, installing, or using ZipherX, you acknowledge that you have read, understood, and agree to this disclaimer in its entirety. If you do not agree, do not use this software.

---

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
git clone https://github.com/VictorLux/ZipherX.git
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
git clone https://github.com/VictorLux/ZipherX.git
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

### Full Node Mode (macOS only)

ZipherX can connect to a local Zclassic full node for enhanced security, full transaction history, and transparent address support. **This mode requires running your own `zclassicd` daemon.**

> **WARNING**: Back up your existing `wallet.dat` and private keys BEFORE enabling Full Node mode. See Section "Backup Your Wallet Before Installation" in the disclaimer above.

#### Prerequisites

| Requirement | Details |
|-------------|---------|
| **zclassicd** | Daemon binary at `/usr/local/bin/zclassicd` |
| **zclassic-cli** | CLI tool at `/usr/local/bin/zclassic-cli` |
| **Blockchain data** | `~/Library/Application Support/Zclassic/blocks/` (~5 GB) |
| **zclassic.conf** | Configuration file (auto-generated if missing) |
| **zstd** | Required for bootstrap extraction (`brew install zstd`) |

#### Required `zclassic.conf` Settings

```ini
server=1
rpcuser=<your_username>
rpcpassword=<your_password>
rpcport=8023
rpcallowip=127.0.0.1
txindex=1
daemon=1
```

ZipherX auto-generates RPC credentials on first setup if no config file exists.

#### Setup

1. **Install the daemon** — Build from source or use the bootstrap installer in **Settings > Full Node > Bootstrap**
2. **Bootstrap the blockchain** — Download via ZipherX (Settings > Full Node > Download Bootstrap) or sync from scratch
3. **Start the daemon** — ZipherX can auto-start `zclassicd`, or start it manually
4. **Select Full Node mode** — On launch, ZipherX detects the running daemon and offers to switch modes

#### Wallet Sources

Full Node mode supports two wallet sources:

| Source | Description |
|--------|-------------|
| **ZipherX Wallet** (recommended) | Keys stay in Secure Enclave. Uses RPC for blockchain queries only. Single shielded address. |
| **wallet.dat** | Uses the daemon's built-in wallet. Supports multiple z-addresses and transparent (t-) addresses. Full RPC wallet operations. |

#### Full Node Features

- **Shielded transactions** — Send/receive via `z_sendmany` with memo support
- **Transparent addresses** — Full t-address support (send, receive, shield coinbase)
- **Shield coinbase** — Convert mining rewards from transparent to shielded (`z_shieldcoinbase`)
- **Multiple addresses** — Create and manage multiple z-addresses and t-addresses
- **Transaction history** — Complete paginated history with filtering (All / Shielded / Transparent)
- **Key management** — Export/import z-keys and t-keys with optional rescan
- **Wallet encryption** — Password-protect `wallet.dat` via daemon
- **Daemon management** — Start, stop, and monitor the daemon from the UI
- **Blockchain explorer** — View block headers, transaction details, network hashrate
- **Tor integration** — Configure SOCKS5 proxy for private peer connections
- **Debug logging** — Toggle debug categories (Network, Mempool, RPC, Tor)
- **Wallet backup** — Create timestamped backups of `wallet.dat` from the UI

#### Network & RPC

| Parameter | Value |
|-----------|-------|
| RPC Port | 8023 (default) |
| RPC Access | localhost only (127.0.0.1) |
| P2P Port | 8033 |
| Sapling Activation | Block 476,969 |

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
