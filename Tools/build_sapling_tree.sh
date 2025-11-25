#!/bin/bash
#
# Build Sapling commitment tree from raw CMUs
# This script compiles and runs the tree builder using the Rust FFI library
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
FFI_DIR="$PROJECT_DIR/Libraries/zipherx-ffi"

echo "🌳 Building Sapling Commitment Tree"
echo "===================================="
echo ""

# Check input file exists
if [ ! -f "$SCRIPT_DIR/commitment_tree.bin" ]; then
    echo "❌ commitment_tree.bin not found!"
    echo "   Run: swift build_commitment_tree.swift first"
    exit 1
fi

# Build macOS version of the library if needed
echo "📦 Building macOS library..."
cd "$FFI_DIR"

# Build for macOS (native)
cargo build --release 2>&1 | tail -5

LIBRARY="$FFI_DIR/target/release/libzipherx_ffi.a"
if [ ! -f "$LIBRARY" ]; then
    echo "❌ Library not found at $LIBRARY"
    exit 1
fi

echo "✅ Library ready: $LIBRARY"
echo ""

# Compile the tree builder
echo "🔨 Compiling tree builder..."
cd "$SCRIPT_DIR"

swiftc -O \
    -import-objc-header "$PROJECT_DIR/Sources/ZipherX-Bridging-Header.h" \
    -L "$FFI_DIR/target/release" \
    -lzipherx_ffi \
    -framework Security \
    -framework Foundation \
    build_tree_from_cmus.swift \
    -o build_tree_from_cmus

echo "✅ Compiled successfully"
echo ""

# Run the tree builder
echo "🚀 Running tree builder..."
echo ""
./build_tree_from_cmus

echo ""
echo "🎉 Done! The sapling_tree.bin can now be bundled with the iOS app."
