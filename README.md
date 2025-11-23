# ZipherX

**EXPERIMENTAL** - Zclassic iOS Wallet for Educational Purposes

[![License: BSL 1.1](https://img.shields.io/badge/License-BSL%201.1-blue.svg)](LICENSE)

> **WARNING: This is experimental software. DO NOT use with real funds. See [DISCLAIMER](DISCLAIMER.md).**

## Overview

ZipherX is an experimental iOS wallet for Zclassic (ZCL) that demonstrates:

- Sapling shielded transactions (z-addresses only)
- Decentralized peer-to-peer networking
- Local zero-knowledge proof generation
- BIP-39 mnemonic seed phrases

## Features

- Fully shielded (z-address to z-address only)
- No trusted third parties
- Local transaction building
- Classic Macintosh System 7 UI theme

## Architecture

- **Swift/SwiftUI** - iOS UI and app logic
- **Rust (librustzcash)** - Sapling cryptography
- **SQLite** - Local encrypted database

## Requirements

- iOS 14.0+
- Xcode 14+
- Rust with iOS targets

## Building

```bash
# Install Rust iOS targets
rustup target add aarch64-apple-ios
rustup target add aarch64-apple-ios-sim

# Build Rust FFI
cd Libraries/zipherx-ffi
cargo build --release --target aarch64-apple-ios
cargo build --release --target aarch64-apple-ios-sim

# Open in Xcode
open ZipherX.xcodeproj
```

## Status

This project is in active development and is **NOT production ready**.

Current limitations:
- Commitment tree for witness generation in progress
- Transaction building may fail
- Not all edge cases handled

## License

This project is licensed under the Business Source License 1.1 - see [LICENSE](LICENSE) for details.

## Disclaimer

**This software is for educational purposes only. It has not been audited and may contain critical security vulnerabilities. Do not use with real cryptocurrency.**

See [DISCLAIMER.md](DISCLAIMER.md) for full details.

---

Copyright (c) 2024 VictorLux. All Rights Reserved.
