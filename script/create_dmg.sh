#!/bin/bash
# Creates a drag-to-Applications DMG for distribution.
# Usage: ./script/create_dmg.sh /path/to/SQLiteGraphStudio.app
# Output: dist/SQLiteGraphStudio.dmg

set -e

APP_PATH="${1:-dist/SQLiteGraphStudio.app}"
DMG_NAME="SQLiteGraphStudio"
DMG_PATH="dist/${DMG_NAME}.dmg"
STAGING_DIR="dist/dmg_staging"

if [ ! -d "$APP_PATH" ]; then
    echo "Error: App not found at $APP_PATH"
    echo "Build and export the app first, then run:"
    echo "  ./script/create_dmg.sh /path/to/SQLiteGraphStudio.app"
    exit 1
fi

echo "Creating DMG from $APP_PATH..."

# Clean up
rm -rf "$STAGING_DIR"
rm -f "$DMG_PATH"
mkdir -p "$STAGING_DIR"

# Copy app and add Applications symlink
cp -R "$APP_PATH" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

# Create DMG
hdiutil create \
    -volname "$DMG_NAME" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

# Clean up staging
rm -rf "$STAGING_DIR"

echo "Done: $DMG_PATH"
