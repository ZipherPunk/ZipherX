#!/bin/bash
# Check App Bundle Tree File
# Verifies which version of commitment_tree_complete.bin is bundled in the app

echo "🔍 Checking bundled tree file in app"
echo "======================================================================"

# Find the most recent ZipherX app bundle
APP_BUNDLE=$(find ~/Library/Developer/CoreSimulator/Devices -name "ZipherX.app" -type d | head -1)

if [ -z "$APP_BUNDLE" ]; then
    echo "❌ ZipherX.app not found in simulator"
    echo "   Make sure the app has been built at least once"
    exit 1
fi

echo "📦 Found app bundle:"
echo "   $APP_BUNDLE"
echo ""

# Check if tree file exists in bundle
BUNDLE_TREE="$APP_BUNDLE/commitment_tree_complete.bin"

if [ ! -f "$BUNDLE_TREE" ]; then
    echo "❌ commitment_tree_complete.bin not found in app bundle"
    exit 1
fi

# Get file size
FILE_SIZE=$(ls -lh "$BUNDLE_TREE" | awk '{print $5}')
echo "📊 Bundled tree file size: $FILE_SIZE"

# Read CMU count from file
COUNT=$(python3 -c "
import struct
with open('$BUNDLE_TREE', 'rb') as f:
    count = struct.unpack('<Q', f.read(8))[0]
    print(f'{count:,}')
")

echo "📊 Bundled tree CMU count: $COUNT"
echo ""

# Compare with source file
SOURCE_TREE="/Users/chris/ZipherX/Resources/commitment_tree_complete.bin"
SOURCE_SIZE=$(ls -lh "$SOURCE_TREE" | awk '{print $5}')
SOURCE_COUNT=$(python3 -c "
import struct
with open('$SOURCE_TREE', 'rb') as f:
    count = struct.unpack('<Q', f.read(8))[0]
    print(f'{count:,}')
")

echo "📊 Source tree file size: $SOURCE_SIZE"
echo "📊 Source tree CMU count: $SOURCE_COUNT"
echo ""

if [ "$COUNT" == "$SOURCE_COUNT" ]; then
    echo "✅ Bundled tree matches source tree"
else
    echo "❌ MISMATCH: Bundled tree does not match source"
    echo "   You need to rebuild the app to bundle the latest tree"
fi

echo ""
echo "Expected CMU count: 1,010,111 (from fresh zcashd export)"
