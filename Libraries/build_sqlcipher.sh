#!/bin/bash
# Build SQLCipher as XCFramework for iOS and macOS
# Uses Apple's Common Crypto for encryption (no OpenSSL dependency)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$SCRIPT_DIR/sqlcipher-src"
BUILD_DIR="$SCRIPT_DIR/sqlcipher-build"
OUTPUT_DIR="$SCRIPT_DIR/SQLCipher.xcframework"

# Clean previous builds
rm -rf "$BUILD_DIR"
rm -rf "$OUTPUT_DIR"
mkdir -p "$BUILD_DIR"

# SQLCipher compiler flags for Apple Common Crypto
SQLCIPHER_CFLAGS="-DSQLITE_HAS_CODEC \
-DSQLCIPHER_CRYPTO_CC \
-DSQLITE_TEMP_STORE=2 \
-DSQLITE_THREADSAFE=1 \
-DSQLITE_ENABLE_FTS5 \
-DSQLITE_ENABLE_JSON1 \
-DSQLITE_DEFAULT_MEMSTATUS=0 \
-DSQLITE_MAX_EXPR_DEPTH=0 \
-DSQLITE_OMIT_DEPRECATED \
-DSQLITE_OMIT_SHARED_CACHE"

echo "================================================"
echo "Building SQLCipher XCFramework"
echo "================================================"

# Function to build for a specific platform
build_platform() {
    local PLATFORM=$1
    local ARCH=$2
    local SDK=$3
    local MIN_VERSION=$4
    local HOST=$5

    echo ""
    echo "Building for $PLATFORM ($ARCH)..."

    local PLATFORM_BUILD_DIR="$BUILD_DIR/$PLATFORM-$ARCH"
    mkdir -p "$PLATFORM_BUILD_DIR"

    # Get SDK path
    local SDK_PATH=$(xcrun --sdk $SDK --show-sdk-path)
    local CC=$(xcrun --sdk $SDK --find clang)

    # Set up environment
    export CC="$CC"
    export CFLAGS="-arch $ARCH -isysroot $SDK_PATH $MIN_VERSION $SQLCIPHER_CFLAGS -Os -fembed-bitcode"
    export LDFLAGS="-arch $ARCH -isysroot $SDK_PATH $MIN_VERSION -framework Security -framework CoreFoundation"

    cd "$SRC_DIR"

    # Clean and configure
    make distclean 2>/dev/null || true

    ./configure \
        --host=$HOST \
        --prefix="$PLATFORM_BUILD_DIR" \
        --disable-shared \
        --enable-static \
        --enable-tempstore=yes \
        --disable-tcl \
        --with-crypto-lib=commoncrypto \
        CFLAGS="$CFLAGS" \
        LDFLAGS="$LDFLAGS"

    # Build only the library (not the CLI which requires editline)
    make clean 2>/dev/null || true
    make -j$(sysctl -n hw.ncpu) libsqlcipher.la

    # Manual install since we're not building everything
    mkdir -p "$PLATFORM_BUILD_DIR/lib"
    mkdir -p "$PLATFORM_BUILD_DIR/include"
    cp .libs/libsqlcipher.a "$PLATFORM_BUILD_DIR/lib/"
    cp sqlite3.h "$PLATFORM_BUILD_DIR/include/"
    cp "$SRC_DIR/src/sqlite3ext.h" "$PLATFORM_BUILD_DIR/include/" 2>/dev/null || true

    echo "✅ Built $PLATFORM ($ARCH)"
}

# Build for iOS Device (arm64)
build_platform "ios" "arm64" "iphoneos" "-mios-version-min=15.0" "arm-apple-darwin"

# Build for iOS Simulator (arm64)
build_platform "ios-simulator" "arm64" "iphonesimulator" "-mios-simulator-version-min=15.0" "arm-apple-darwin"

# Build for iOS Simulator (x86_64)
build_platform "ios-simulator" "x86_64" "iphonesimulator" "-mios-simulator-version-min=15.0" "x86_64-apple-darwin"

# Build for macOS (arm64)
build_platform "macos" "arm64" "macosx" "-mmacosx-version-min=12.0" "arm-apple-darwin"

# Build for macOS (x86_64)
build_platform "macos" "x86_64" "macosx" "-mmacosx-version-min=12.0" "x86_64-apple-darwin"

echo ""
echo "================================================"
echo "Creating fat libraries..."
echo "================================================"

# Create fat library for iOS Simulator (arm64 + x86_64)
mkdir -p "$BUILD_DIR/ios-simulator-universal/lib"
mkdir -p "$BUILD_DIR/ios-simulator-universal/include"
lipo -create \
    "$BUILD_DIR/ios-simulator-arm64/lib/libsqlcipher.a" \
    "$BUILD_DIR/ios-simulator-x86_64/lib/libsqlcipher.a" \
    -output "$BUILD_DIR/ios-simulator-universal/lib/libsqlcipher.a"
cp -r "$BUILD_DIR/ios-simulator-arm64/include/"* "$BUILD_DIR/ios-simulator-universal/include/"
echo "✅ Created iOS Simulator universal library"

# Create fat library for macOS (arm64 + x86_64)
mkdir -p "$BUILD_DIR/macos-universal/lib"
mkdir -p "$BUILD_DIR/macos-universal/include"
lipo -create \
    "$BUILD_DIR/macos-arm64/lib/libsqlcipher.a" \
    "$BUILD_DIR/macos-x86_64/lib/libsqlcipher.a" \
    -output "$BUILD_DIR/macos-universal/lib/libsqlcipher.a"
cp -r "$BUILD_DIR/macos-arm64/include/"* "$BUILD_DIR/macos-universal/include/"
echo "✅ Created macOS universal library"

echo ""
echo "================================================"
echo "Creating XCFramework..."
echo "================================================"

xcodebuild -create-xcframework \
    -library "$BUILD_DIR/ios-arm64/lib/libsqlcipher.a" \
    -headers "$BUILD_DIR/ios-arm64/include" \
    -library "$BUILD_DIR/ios-simulator-universal/lib/libsqlcipher.a" \
    -headers "$BUILD_DIR/ios-simulator-universal/include" \
    -library "$BUILD_DIR/macos-universal/lib/libsqlcipher.a" \
    -headers "$BUILD_DIR/macos-universal/include" \
    -output "$OUTPUT_DIR"

echo ""
echo "================================================"
echo "✅ SQLCipher.xcframework created successfully!"
echo "================================================"
echo ""
echo "Location: $OUTPUT_DIR"
echo ""

# Show library info
echo "Library architectures:"
for lib in "$OUTPUT_DIR"/*/libsqlcipher.a; do
    echo "  $(dirname $lib | xargs basename):"
    lipo -info "$lib" | sed 's/^/    /'
done

# Cleanup build directory
# rm -rf "$BUILD_DIR"
# rm -rf "$SRC_DIR"

echo ""
echo "Done! Add SQLCipher.xcframework to your Xcode project."
