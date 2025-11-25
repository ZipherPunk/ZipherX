#!/bin/bash
set -e

echo "🦀 Building ZipherX Rust FFI for iOS"
echo "======================================="

cd "$(dirname "$0")/zipherx-ffi"

# Ensure iOS targets are installed
echo "📦 Checking Rust targets..."
rustup target add aarch64-apple-ios 2>/dev/null || true
rustup target add x86_64-apple-ios 2>/dev/null || true
rustup target add aarch64-apple-ios-sim 2>/dev/null || true

# Build for iOS device (arm64)
echo ""
echo "🔨 Building for iOS device (arm64)..."
cargo build --release --target aarch64-apple-ios

# Build for iOS simulator (x86_64 + arm64)
echo ""
echo "🔨 Building for iOS simulator (x86_64)..."
cargo build --release --target x86_64-apple-ios

echo ""
echo "🔨 Building for iOS simulator (arm64)..."
cargo build --release --target aarch64-apple-ios-sim

# Create universal binary for simulator
echo ""
echo "🔗 Creating universal simulator binary..."
mkdir -p target/universal-ios-sim/release
lipo -create \
    target/x86_64-apple-ios/release/libzipherx_ffi.a \
    target/aarch64-apple-ios-sim/release/libzipherx_ffi.a \
    -output target/universal-ios-sim/release/libzipherx_ffi.a

# Copy to xcframework locations
echo ""
echo "📦 Copying libraries to XCFramework..."

# iOS device
cp target/aarch64-apple-ios/release/libzipherx_ffi.a \
   ../ZipherXFFI.xcframework/ios-arm64/libzipherx_ffi.a

# iOS simulator (universal binary for both x86_64 and arm64)
cp target/universal-ios-sim/release/libzipherx_ffi.a \
   ../ZipherXFFI.xcframework/ios-arm64_x86_64-simulator/libzipherx_ffi.a

# Also copy as libzipherx_ffi_sim.a (some projects use this name)
cp target/universal-ios-sim/release/libzipherx_ffi.a \
   ../ZipherXFFI.xcframework/ios-arm64_x86_64-simulator/libzipherx_ffi_sim.a

echo ""
echo "✅ FFI library built and copied successfully!"
echo ""
echo "📊 Library sizes:"
ls -lh ../ZipherXFFI.xcframework/ios-arm64/libzipherx_ffi.a
ls -lh ../ZipherXFFI.xcframework/ios-arm64_x86_64-simulator/libzipherx_ffi.a

echo ""
echo "🎉 Done! You can now rebuild the Xcode project."
