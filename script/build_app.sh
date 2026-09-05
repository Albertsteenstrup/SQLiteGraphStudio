#!/bin/bash
# Builds a universal SQLiteGraphStudio.app and creates a DMG for distribution.
# Usage: ./script/build_app.sh
# Output: dist/SQLiteGraphStudio.dmg

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/bundle_metadata.sh"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"
NOTARYTOOL_PROFILE="${NOTARYTOOL_PROFILE:-}"
if [[ -n "$NOTARYTOOL_PROFILE" && "$SIGNING_IDENTITY" != "Developer ID Application: "* ]]; then
    echo "Notarization requires SIGNING_IDENTITY to name a Developer ID Application certificate." >&2
    exit 2
fi
DIST_DIR="$PROJECT_DIR/dist"
APP_NAME="SQLiteGraphStudio"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
DMG_PATH="$DIST_DIR/$APP_NAME.dmg"
ICNS_PATH="$SCRIPT_DIR/AppIcon.icns"
MIN_MACOS_VERSION="$(sgs_metadata LSMinimumSystemVersion)"
ARCHS=("arm64" "x86_64")
UNIVERSAL_BINARY="$DIST_DIR/$APP_NAME.universal"

echo "==> Building universal release binary (${ARCHS[*]})..."
cd "$PROJECT_DIR"

rm -f "$UNIVERSAL_BINARY"
mkdir -p "$DIST_DIR"

BINARY_PATHS=()
RESOURCE_BUILD_DIR=""

for arch in "${ARCHS[@]}"; do
    triple="$arch-apple-macosx$MIN_MACOS_VERSION"

    echo "    Building $arch ($triple)..."
    swift build -c release --product "$APP_NAME" --triple "$triple"

    build_dir="$(swift build -c release --triple "$triple" --show-bin-path)"
    binary_path="$build_dir/$APP_NAME"

    if [ ! -f "$binary_path" ]; then
        echo "Error: Expected binary not found at $binary_path"
        exit 1
    fi

    if ! lipo -archs "$binary_path" | grep -qw "$arch"; then
        echo "Error: $binary_path does not contain expected architecture $arch"
        exit 1
    fi

    BINARY_PATHS+=("$binary_path")

    if [ "$arch" = "arm64" ]; then
        RESOURCE_BUILD_DIR="$build_dir"
    fi
done

lipo -create "${BINARY_PATHS[@]}" -output "$UNIVERSAL_BINARY"

if ! lipo -archs "$UNIVERSAL_BINARY" | grep -qw "arm64" || ! lipo -archs "$UNIVERSAL_BINARY" | grep -qw "x86_64"; then
    echo "Error: Universal binary is missing arm64 or x86_64"
    exit 1
fi

echo "    Architectures: $(lipo -archs "$UNIVERSAL_BINARY")"

echo "==> Assembling .app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy binary
cp "$UNIVERSAL_BINARY" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Copy icon
if [ -f "$ICNS_PATH" ]; then
    cp "$ICNS_PATH" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
    echo "    Icon: $ICNS_PATH"
else
    echo "    Warning: AppIcon.icns not found at $ICNS_PATH, skipping icon"
fi

# Copy all resource bundles produced by the build
for bundle in "$RESOURCE_BUILD_DIR/"*.bundle; do
    if [ -d "$bundle" ]; then
        cp -R "$bundle" "$APP_BUNDLE/Contents/Resources/"
        echo "    Resources: $(basename "$bundle")"
    fi
done

# Strip macOS metadata that breaks codesigning (ignore permission errors from iCloud)
chmod -R u+rw "$APP_BUNDLE" 2>/dev/null || true
xattr -cr "$APP_BUNDLE" 2>/dev/null || true
find "$APP_BUNDLE" -name ".DS_Store" -delete 2>/dev/null || true

sgs_write_metadata "$APP_BUNDLE/Contents/Info.plist"

if [[ -n "$SIGNING_IDENTITY" ]]; then
    # The current app has one Mach-O executable and resource-only bundles.
    codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP_BUNDLE"
    codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
else
    echo "Unsigned artifact for local testing; not ready for distribution."
fi

echo "==> App bundle: $APP_BUNDLE"

bash "$SCRIPT_DIR/create_dmg.sh" "$APP_BUNDLE" "$DMG_PATH"
if [[ -n "$SIGNING_IDENTITY" ]]; then
    codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$DMG_PATH"
    codesign --verify --strict --verbose=2 "$DMG_PATH"
fi

echo ""
echo "==> Done: $DMG_PATH"
if [[ -n "$NOTARYTOOL_PROFILE" ]]; then
    xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARYTOOL_PROFILE" --wait
    xcrun stapler staple "$DMG_PATH"
    xcrun stapler validate "$DMG_PATH"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG_PATH"
    echo "Notarization and local assessment completed. Nothing was published or installed."
else
    echo "Not notarized. See docs/packaging.md before distribution."
fi
