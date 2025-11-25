#!/bin/bash
#
# Build tree with witnesses for your notes
# This scans the blockchain, finds your notes, and generates proper witnesses
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
FFI_DIR="$PROJECT_DIR/Libraries/zipherx-ffi"

echo "🌳 Building Sapling Tree with Witnesses"
echo "========================================"
echo ""

# Check IVK argument
if [ -z "$1" ]; then
    echo "Usage: ./build_witnesses.sh <ivk_hex>"
    echo ""
    echo "To get your IVK from spending key, you can use the app or derive it."
    echo "The IVK is 32 bytes (64 hex characters)."
    exit 1
fi

IVK="$1"

# Build macOS library if needed
echo "📦 Building macOS library..."
cd "$FFI_DIR"
cargo build --release 2>&1 | tail -5

LIBRARY="$FFI_DIR/target/release/libzipherx_ffi.a"
if [ ! -f "$LIBRARY" ]; then
    echo "❌ Library not found at $LIBRARY"
    exit 1
fi

echo "✅ Library ready"
echo ""

# Compile the tool
echo "🔨 Compiling tree builder with witnesses..."
cd "$SCRIPT_DIR"

swiftc -O \
    -import-objc-header "$PROJECT_DIR/Sources/ZipherX-Bridging-Header.h" \
    -L "$FFI_DIR/target/release" \
    -lzipherx_ffi \
    -framework Security \
    -framework Foundation \
    build_tree_with_witnesses.swift \
    -o build_tree_with_witnesses

echo "✅ Compiled successfully"
echo ""

# Run
echo "🚀 Running tree builder..."
echo ""
./build_tree_with_witnesses "$IVK"

echo ""
echo "🎉 Done!"
echo ""
echo "Output files:"
echo "  - sapling_tree_with_witnesses.bin (tree state)"
echo "  - note_witnesses.bin (your notes with witnesses)"
echo ""
echo "To use in the app, copy sapling_tree_with_witnesses.bin to Resources/sapling_tree.bin"
