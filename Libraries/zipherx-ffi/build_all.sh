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

# FIX #201: Set deployment targets to match Xcode project settings
# This prevents "built for newer macOS" linker warnings
export MACOSX_DEPLOYMENT_TARGET=12.0
export IPHONEOS_DEPLOYMENT_TARGET=14.0

echo "📱 Deployment targets: macOS $MACOSX_DEPLOYMENT_TARGET, iOS $IPHONEOS_DEPLOYMENT_TARGET"
echo ""

# FIX #203: Build all targets IN PARALLEL (4x faster!)
echo "═══════════════════════════════════════════════════════════════"
echo "🚀 Building LIBRARIES ONLY in PARALLEL..."
echo "═══════════════════════════════════════════════════════════════"
echo "⚠️  Note: Building --lib only to avoid binary linking issues"

# Start all builds in background (LIB ONLY!)
echo "🔨 [1/4] macOS (arm64)..."
cargo build --release --lib > /tmp/build_macos_arm64.log 2>&1 &
PID1=$!

echo "🔨 [2/4] macOS (x86_64)..."
cargo build --release --lib --target x86_64-apple-darwin > /tmp/build_macos_x86.log 2>&1 &
PID2=$!

echo "🔨 [3/4] iOS Device (arm64)..."
cargo build --release --lib --target aarch64-apple-ios > /tmp/build_ios.log 2>&1 &
PID3=$!

echo "🔨 [4/4] iOS Simulator (arm64)..."
cargo build --release --lib --target aarch64-apple-ios-sim > /tmp/build_sim.log 2>&1 &
PID4=$!

echo ""
echo "⏳ Waiting for all builds to complete (running in parallel)..."

# Wait for each and check exit status
FAILED=0

wait $PID1
STATUS1=$?
if [ $STATUS1 -eq 0 ]; then echo "✅ macOS (arm64) done"; else echo "❌ macOS (arm64) FAILED (exit code: $STATUS1)"; FAILED=1; fi

wait $PID2
STATUS2=$?
if [ $STATUS2 -eq 0 ]; then echo "✅ macOS (x86_64) done"; else echo "❌ macOS (x86_64) FAILED (exit code: $STATUS2)"; FAILED=1; fi

wait $PID3
STATUS3=$?
if [ $STATUS3 -eq 0 ]; then echo "✅ iOS Device done"; else echo "❌ iOS Device FAILED (exit code: $STATUS3)"; FAILED=1; fi

wait $PID4
STATUS4=$?
if [ $STATUS4 -eq 0 ]; then echo "✅ iOS Simulator done"; else echo "❌ iOS Simulator FAILED (exit code: $STATUS4)"; FAILED=1; fi

if [ $FAILED -eq 1 ]; then
    echo ""
    echo "❌ BUILD FAILED! Check logs:"
    echo "   /tmp/build_macos_arm64.log"
    echo "   /tmp/build_macos_x86.log"
    echo "   /tmp/build_ios.log"
    echo "   /tmp/build_sim.log"
    exit 1
fi

echo ""
echo "✅ All 4 library targets built successfully!"

# Create universal macOS library
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "🔗 Creating universal macOS library (lipo)..."
echo "═══════════════════════════════════════════════════════════════"
lipo -create \
    target/release/libzipherx_ffi.a \
    target/x86_64-apple-darwin/release/libzipherx_ffi.a \
    -output "$PROJECT_DIR/Libraries/libzipherx_ffi.a"

# Verify universal library
echo "✅ Universal macOS library:"
lipo -info "$PROJECT_DIR/Libraries/libzipherx_ffi.a"

# Copy to xcframework
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "📦 Updating XCFramework..."
echo "═══════════════════════════════════════════════════════════════"

# macOS (copy to xcframework if the directory exists)
if [ -d "$XCFRAMEWORK_DIR/macos-arm64_x86_64" ]; then
    echo "  → macOS XCFramework (arm64 + x86_64)..."
    cp "$PROJECT_DIR/Libraries/libzipherx_ffi.a" \
       "$XCFRAMEWORK_DIR/macos-arm64_x86_64/libzipherx_ffi.a"
else
    echo "  → macOS: Using standalone library (no XCFramework)"
fi

# iOS Device
echo "  → iOS Device (arm64)..."
cp target/aarch64-apple-ios/release/libzipherx_ffi.a \
   "$XCFRAMEWORK_DIR/ios-arm64/libzipherx_ffi.a"

# iOS Simulator
echo "  → iOS Simulator (arm64)..."
cp target/aarch64-apple-ios-sim/release/libzipherx_ffi.a \
   "$XCFRAMEWORK_DIR/ios-arm64-simulator/libzipherx_ffi.a"

cp /Users/chris/ZipherX/Libraries/zipherx-ffi/include/zipherx_ffi.h /Users/chris/ZipherX/Libraries/ZipherXFFI.xcframework/macos-arm64_x86_64/Headers/
cp /Users/chris/ZipherX/Libraries/zipherx-ffi/include/zipherx_ffi.h /Users/chris/ZipherX/Libraries/ZipherXFFI.xcframework/ios-arm64/Headers/
cp /Users/chris/ZipherX/Libraries/zipherx-ffi/include/zipherx_ffi.h /Users/chris/ZipherX/Libraries/ZipherXFFI.xcframework/ios-arm64-simulator/Headers/


# Verify libraries
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "🔍 Verifying updated libraries..."
echo "═══════════════════════════════════════════════════════════════"

echo ""
echo "macOS standalone library:"
ls -la "$PROJECT_DIR/Libraries/libzipherx_ffi.a"
lipo -info "$PROJECT_DIR/Libraries/libzipherx_ffi.a"

echo ""
echo "iOS Device:"
ls -la "$XCFRAMEWORK_DIR/ios-arm64/libzipherx_ffi.a"

echo ""
echo "iOS Simulator:"
ls -la "$XCFRAMEWORK_DIR/ios-arm64-simulator/libzipherx_ffi.a"

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
