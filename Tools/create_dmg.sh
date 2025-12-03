#!/bin/bash

# ZipherX DMG Creator Script
# Usage: ./create_dmg.sh [path_to_app]

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}╔════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║       ZipherX DMG Creator              ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════╝${NC}"
echo ""

# Configuration
APP_NAME="ZipherXMac"
VOLUME_NAME="ZipherX"
DMG_NAME="ZipherX-macOS"
VERSION="1.0"
OUTPUT_DIR="$HOME/Desktop"
TEMP_DIR="/tmp/ZipherX-DMG-$$"

# Find the app
if [ -n "$1" ]; then
    APP_PATH="$1"
elif [ -d "$HOME/Desktop/${APP_NAME}.app" ]; then
    APP_PATH="$HOME/Desktop/${APP_NAME}.app"
elif [ -d "/Users/chris/ZipherX/build/Release/${APP_NAME}.app" ]; then
    APP_PATH="/Users/chris/ZipherX/build/Release/${APP_NAME}.app"
else
    echo -e "${YELLOW}Looking for ${APP_NAME}.app...${NC}"

    # Try to find in DerivedData
    DERIVED_APP=$(find ~/Library/Developer/Xcode/DerivedData -name "${APP_NAME}.app" -type d 2>/dev/null | head -1)

    if [ -n "$DERIVED_APP" ]; then
        APP_PATH="$DERIVED_APP"
    else
        echo -e "${RED}Error: Could not find ${APP_NAME}.app${NC}"
        echo ""
        echo "Please either:"
        echo "  1. Build the app in Xcode (Product → Build)"
        echo "  2. Archive and export (Product → Archive → Distribute App → Copy App)"
        echo "  3. Provide the path as argument: ./create_dmg.sh /path/to/${APP_NAME}.app"
        exit 1
    fi
fi

echo -e "${GREEN}Found app:${NC} $APP_PATH"

# Verify app exists
if [ ! -d "$APP_PATH" ]; then
    echo -e "${RED}Error: App not found at $APP_PATH${NC}"
    exit 1
fi

# Get version from app if possible
if [ -f "$APP_PATH/Contents/Info.plist" ]; then
    PLIST_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo "1.0")
    VERSION="$PLIST_VERSION"
fi

DMG_FILENAME="${DMG_NAME}-${VERSION}.dmg"
DMG_PATH="${OUTPUT_DIR}/${DMG_FILENAME}"

echo -e "${GREEN}Version:${NC} $VERSION"
echo -e "${GREEN}Output:${NC} $DMG_PATH"
echo ""

# Clean up any previous temp directory
rm -rf "$TEMP_DIR"
mkdir -p "$TEMP_DIR"

echo -e "${YELLOW}Copying app to staging area...${NC}"
cp -R "$APP_PATH" "$TEMP_DIR/"

echo -e "${YELLOW}Creating Applications symlink...${NC}"
ln -s /Applications "$TEMP_DIR/Applications"

# Check if create-dmg is installed (makes nicer DMGs)
if command -v create-dmg &> /dev/null; then
    echo -e "${YELLOW}Creating styled DMG with create-dmg...${NC}"

    # Remove existing DMG if present
    rm -f "$DMG_PATH"

    create-dmg \
        --volname "$VOLUME_NAME" \
        --window-pos 200 120 \
        --window-size 600 400 \
        --icon-size 100 \
        --icon "${APP_NAME}.app" 150 190 \
        --app-drop-link 450 190 \
        --hide-extension "${APP_NAME}.app" \
        "$DMG_PATH" \
        "$TEMP_DIR" || true

else
    echo -e "${YELLOW}Creating DMG with hdiutil...${NC}"
    echo -e "${YELLOW}(Install 'brew install create-dmg' for nicer DMGs)${NC}"

    # Remove existing DMG if present
    rm -f "$DMG_PATH"

    hdiutil create \
        -volname "$VOLUME_NAME" \
        -srcfolder "$TEMP_DIR" \
        -ov \
        -format UDZO \
        "$DMG_PATH"
fi

# Clean up
rm -rf "$TEMP_DIR"

# Verify DMG was created
if [ -f "$DMG_PATH" ]; then
    DMG_SIZE=$(du -h "$DMG_PATH" | cut -f1)
    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║           DMG Created Successfully!    ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${GREEN}File:${NC} $DMG_PATH"
    echo -e "${GREEN}Size:${NC} $DMG_SIZE"
    echo ""
    echo -e "${YELLOW}Note: This is an unsigned DMG.${NC}"
    echo -e "${YELLOW}Users will need to right-click → Open → Open to bypass Gatekeeper.${NC}"

    # Open the folder containing the DMG
    open -R "$DMG_PATH"
else
    echo -e "${RED}Error: DMG creation failed${NC}"
    exit 1
fi
