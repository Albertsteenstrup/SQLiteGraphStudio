#!/bin/bash
# Builds SQLiteGraphStudio.app and creates a DMG for distribution.
# Usage: ./script/build_app.sh
# Output: dist/SQLiteGraphStudio.dmg

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DIST_DIR="$PROJECT_DIR/dist"
APP_NAME="SQLiteGraphStudio"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
DMG_PATH="$DIST_DIR/$APP_NAME.dmg"
STAGING_DIR="$DIST_DIR/dmg_staging"
ICNS_PATH="$SCRIPT_DIR/AppIcon.icns"

echo "==> Building release binary..."
cd "$PROJECT_DIR"
swift build -c release --product SQLiteGraphStudio

BINARY_PATH="$PROJECT_DIR/.build/release/SQLiteGraphStudio"

echo "==> Assembling .app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy binary
cp "$BINARY_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Copy icon
if [ -f "$ICNS_PATH" ]; then
    cp "$ICNS_PATH" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
    echo "    Icon: $ICNS_PATH"
else
    echo "    Warning: AppIcon.icns not found at $ICNS_PATH, skipping icon"
fi

# Copy all resource bundles produced by the build
for bundle in "$PROJECT_DIR/.build/release/"*.bundle; do
    if [ -d "$bundle" ]; then
        cp -R "$bundle" "$APP_BUNDLE/Contents/Resources/"
        echo "    Resources: $(basename "$bundle")"
    fi
done

# Strip macOS metadata that breaks codesigning (ignore permission errors from iCloud)
chmod -R u+rw "$APP_BUNDLE" 2>/dev/null || true
xattr -cr "$APP_BUNDLE" 2>/dev/null || true
find "$APP_BUNDLE" -name ".DS_Store" -delete 2>/dev/null || true

# Write Info.plist (must come after xattr strip)

# Write Info.plist
cat > "$APP_BUNDLE/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>SQLiteGraphStudio</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.albertsteenstrup.sqlitegraphstudio</string>
    <key>CFBundleName</key>
    <string>SQLite Graph Studio</string>
    <key>CFBundleDisplayName</key>
    <string>SQLite Graph Studio</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.2.0</string>
    <key>CFBundleVersion</key>
    <string>2</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeExtensions</key>
            <array>
                <string>sqlite</string>
                <string>sqlite3</string>
                <string>db</string>
            </array>
            <key>CFBundleTypeRole</key>
            <string>Editor</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
        </dict>
    </array>
</dict>
</plist>
PLIST

echo "==> App bundle: $APP_BUNDLE"

echo "==> Creating DMG..."
rm -rf "$STAGING_DIR"
rm -f "$DMG_PATH"
mkdir -p "$STAGING_DIR"

cp -R "$APP_BUNDLE" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

rm -rf "$STAGING_DIR"

echo ""
echo "==> Done: $DMG_PATH"
echo "    Upload this file to your GitHub Release."
echo ""
echo "==> To sign the app (removes 'damaged' error for users):"
echo "    codesign --deep --force --options runtime --sign \"Apple Development: YOUR_APPLE_ID (YOUR_TEAM_ID)\" $APP_BUNDLE"
echo "    Then re-run: ./script/create_dmg.sh $APP_BUNDLE"
