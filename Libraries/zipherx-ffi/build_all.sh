#!/bin/bash
# ZipherX FFI Library Build Script
# Builds for all platforms and updates xcframework

set -e  # Exit on error

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
XCFRAMEWORK_DIR="$PROJECT_DIR/Libraries/ZipherXFFI.xcframework"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║         ZipherX FFI Library Build Script                     ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "📁 Script directory: $SCRIPT_DIR"
echo "📁 Project directory: $PROJECT_DIR"
echo "📁 XCFramework directory: $XCFRAMEWORK_DIR"
echo ""

cd "$SCRIPT_DIR"

# Build all targets
echo "═══════════════════════════════════════════════════════════════"
echo "🔨 Building for macOS (arm64)..."
echo "═══════════════════════════════════════════════════════════════"
cargo build --release

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "🔨 Building for macOS (x86_64)..."
echo "═══════════════════════════════════════════════════════════════"
cargo build --release --target x86_64-apple-darwin

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "🔨 Building for iOS Device (arm64)..."
echo "═══════════════════════════════════════════════════════════════"
cargo build --release --target aarch64-apple-ios

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "🔨 Building for iOS Simulator (arm64)..."
echo "═══════════════════════════════════════════════════════════════"
cargo build --release --target aarch64-apple-ios-sim

# Create universal macOS library
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "🔗 Creating universal macOS library (lipo)..."
echo "═══════════════════════════════════════════════════════════════"
lipo -create \
    target/release/libzipherx_ffi.a \
    target/x86_64-apple-darwin/release/libzipherx_ffi.a \
    -output "$PROJECT_DIR/Libraries/libzipherx_ffi_macos.a"

# Verify universal library
echo "✅ Universal macOS library:"
lipo -info "$PROJECT_DIR/Libraries/libzipherx_ffi_macos.a"

# Copy to xcframework
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "📦 Updating XCFramework..."
echo "═══════════════════════════════════════════════════════════════"

# macOS
echo "  → macOS (arm64 + x86_64)..."
cp "$PROJECT_DIR/Libraries/libzipherx_ffi_macos.a" \
   "$XCFRAMEWORK_DIR/macos-arm64_x86_64/libzipherx_ffi_macos_universal.a"

# iOS Device
echo "  → iOS Device (arm64)..."
cp target/aarch64-apple-ios/release/libzipherx_ffi.a \
   "$XCFRAMEWORK_DIR/ios-arm64/libzipherx_ffi.a"

# iOS Simulator
echo "  → iOS Simulator (arm64)..."
cp target/aarch64-apple-ios-sim/release/libzipherx_ffi.a \
   "$XCFRAMEWORK_DIR/ios-arm64-simulator/libzipherx_ffi.a"

# Verify libraries
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "🔍 Verifying updated libraries..."
echo "═══════════════════════════════════════════════════════════════"

echo ""
echo "macOS ($(ls -lh "$XCFRAMEWORK_DIR/macos-arm64_x86_64/libzipherx_ffi_macos_universal.a" | awk '{print $5}')):"
ls -la "$XCFRAMEWORK_DIR/macos-arm64_x86_64/libzipherx_ffi_macos_universal.a"
strings "$XCFRAMEWORK_DIR/macos-arm64_x86_64/libzipherx_ffi_macos_universal.a" 2>/dev/null | grep -i "fixed port" | head -1 || echo "  ⚠️ 'fixed port' string not found"

echo ""
echo "iOS Device ($(ls -lh "$XCFRAMEWORK_DIR/ios-arm64/libzipherx_ffi.a" | awk '{print $5}')):"
ls -la "$XCFRAMEWORK_DIR/ios-arm64/libzipherx_ffi.a"
strings "$XCFRAMEWORK_DIR/ios-arm64/libzipherx_ffi.a" 2>/dev/null | grep -i "fixed port" | head -1 || echo "  ⚠️ 'fixed port' string not found"

echo ""
echo "iOS Simulator ($(ls -lh "$XCFRAMEWORK_DIR/ios-arm64-simulator/libzipherx_ffi.a" | awk '{print $5}')):"
ls -la "$XCFRAMEWORK_DIR/ios-arm64-simulator/libzipherx_ffi.a"
strings "$XCFRAMEWORK_DIR/ios-arm64-simulator/libzipherx_ffi.a" 2>/dev/null | grep -i "fixed port" | head -1 || echo "  ⚠️ 'fixed port' string not found"

# Clean Xcode DerivedData
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "🧹 Cleaning Xcode DerivedData..."
echo "═══════════════════════════════════════════════════════════════"
rm -rf ~/Library/Developer/Xcode/DerivedData/ZipherX-*
echo "✅ Xcode cache cleared"

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                    BUILD COMPLETE!                           ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  All libraries updated in XCFramework.                       ║"
echo "║  Xcode DerivedData cleared.                                  ║"
echo "║                                                              ║"
echo "║  Next: Open Xcode and Build (⌘B)                            ║"
echo "╚══════════════════════════════════════════════════════════════╝"
