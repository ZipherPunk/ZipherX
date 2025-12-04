# SQLCipher Integration Guide

## Current Status

ZipherX now has full support for SQLCipher database encryption. The code automatically:
- Detects if SQLCipher is available
- Uses full database encryption when SQLCipher is present
- Falls back to iOS Data Protection + field-level AES-GCM encryption when not

## Adding SQLCipher to the Project

### Option 1: CocoaPods (Recommended for iOS)

1. Create or update `Podfile`:
```ruby
platform :ios, '15.0'
use_frameworks!

target 'ZipherX' do
  pod 'SQLCipher', '~> 4.5'
end

target 'ZipherXMac' do
  pod 'SQLCipher', '~> 4.5'
end
```

2. Install:
```bash
pod install
```

3. Open `ZipherX.xcworkspace` instead of `.xcodeproj`

### Option 2: Swift Package Manager

Add to `Package.swift`:
```swift
dependencies: [
    .package(url: "https://github.com/nicklockwood/SQLite.swift.git", from: "0.14.1"),
]
```

Note: SQLite.swift includes SQLCipher support but requires additional configuration.

### Option 3: Build SQLCipher as XCFramework

1. Clone SQLCipher:
```bash
cd /Users/chris/ZipherX/Libraries
git clone https://github.com/nicklockwood/SQLCipher.git
```

2. Build for iOS:
```bash
cd SQLCipher
./configure --enable-tempstore=yes \
    --with-crypto-lib=commoncrypto \
    CFLAGS="-DSQLITE_HAS_CODEC -DSQLCIPHER_CRYPTO_CC"
make
```

3. Create XCFramework with iOS, iOS Simulator, and macOS slices

### Option 4: Use Pre-built Binary

Download pre-built SQLCipher from:
- https://www.zetetic.net/sqlcipher/open-source/

## Verification

After adding SQLCipher, the app will show in Settings → Security:
- "Database Encryption: Full" with green checkmark
- "SQLCipher: AES-256 full database encryption"

If SQLCipher is not available, it shows:
- "Database Encryption: Field-level" with orange shield
- "iOS Data Protection + AES-GCM field encryption"

## Security Notes

### With SQLCipher
- Entire database file is encrypted with AES-256
- Encryption key derived from device ID + random salt using HKDF-SHA256
- Salt stored securely in iOS Keychain
- Automatic migration of existing unencrypted databases

### Without SQLCipher (Current Fallback)
- iOS Data Protection encrypts file at rest (FileProtectionType.completeUnlessOpen)
- Sensitive fields encrypted with AES-GCM-256:
  - diversifier (address component)
  - rcm (randomness commitment)
  - memo (user message)
  - witness (Merkle path)
- Key derived from device ID using HKDF-SHA256

Both modes provide strong protection. SQLCipher adds defense-in-depth.

## Migration

When SQLCipher becomes available on an existing installation:
1. App detects unencrypted database
2. Creates encrypted copy using `sqlcipher_export`
3. Backs up original
4. Replaces with encrypted version
5. Removes backup on success

If migration fails, original database is restored automatically.
