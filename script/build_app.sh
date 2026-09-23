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
UNIVERSAL_MCP_BINARY="$DIST_DIR/StudioMCP.universal"
POCKET_TTS_REQUIRED="${SGS_POCKET_TTS_RUNTIME_REQUIRED:-0}"
if [[ "$POCKET_TTS_REQUIRED" != "0" && "$POCKET_TTS_REQUIRED" != "1" ]]; then
    echo "SGS_POCKET_TTS_RUNTIME_REQUIRED must be 0 or 1." >&2
    exit 2
fi
if [[ "$POCKET_TTS_REQUIRED" == "1" && -z "${SGS_POCKET_TTS_RUNTIME:-}" ]]; then
    echo "Pocket TTS was required for this release, but SGS_POCKET_TTS_RUNTIME is unset." >&2
    exit 2
fi

if [[ -n "${SGS_POSTGRES_RUNTIME:-}" ]]; then
    SGS_POSTGRES_RUNTIME="$(python3 "$SCRIPT_DIR/package_postgres_runtime.py" check-source "$SGS_POSTGRES_RUNTIME" "$APP_BUNDLE")"
fi
if [[ -n "${SGS_POCKET_TTS_RUNTIME:-}" ]]; then
    SGS_POCKET_TTS_RUNTIME="$(python3 "$SCRIPT_DIR/package_pocket_tts_runtime.py" check-source \
        "$SGS_POCKET_TTS_RUNTIME" "$APP_BUNDLE" "${ARCHS[@]}")"
fi

echo "==> Building universal release binary (${ARCHS[*]})..."
cd "$PROJECT_DIR"

rm -f "$UNIVERSAL_BINARY"
rm -f "$UNIVERSAL_MCP_BINARY"
mkdir -p "$DIST_DIR"

BINARY_PATHS=()
MCP_BINARY_PATHS=()
RESOURCE_BUILD_DIR=""

for arch in "${ARCHS[@]}"; do
    triple="$arch-apple-macosx$MIN_MACOS_VERSION"

    echo "    Building $arch ($triple)..."
    swift build -c release --product "$APP_NAME" --triple "$triple"
    swift build -c release --product StudioMCP --triple "$triple"

    build_dir="$(swift build -c release --triple "$triple" --show-bin-path)"
    binary_path="$build_dir/$APP_NAME"
    mcp_binary_path="$build_dir/StudioMCP"

    if [ ! -f "$binary_path" ] || [ ! -f "$mcp_binary_path" ]; then
        echo "Error: Expected app or MCP helper binary not found in $build_dir"
        exit 1
    fi

    if ! lipo -archs "$binary_path" | grep -qw "$arch" || ! lipo -archs "$mcp_binary_path" | grep -qw "$arch"; then
        echo "Error: App or MCP helper does not contain expected architecture $arch"
        exit 1
    fi

    BINARY_PATHS+=("$binary_path")
    MCP_BINARY_PATHS+=("$mcp_binary_path")

    if [ "$arch" = "arm64" ]; then
        RESOURCE_BUILD_DIR="$build_dir"
    fi
done

lipo -create "${BINARY_PATHS[@]}" -output "$UNIVERSAL_BINARY"
lipo -create "${MCP_BINARY_PATHS[@]}" -output "$UNIVERSAL_MCP_BINARY"

if ! lipo -archs "$UNIVERSAL_BINARY" | grep -qw "arm64" || ! lipo -archs "$UNIVERSAL_BINARY" | grep -qw "x86_64" \
   || ! lipo -archs "$UNIVERSAL_MCP_BINARY" | grep -qw "arm64" || ! lipo -archs "$UNIVERSAL_MCP_BINARY" | grep -qw "x86_64"; then
    echo "Error: Universal app or MCP helper is missing arm64 or x86_64"
    exit 1
fi

echo "    Architectures: $(lipo -archs "$UNIVERSAL_BINARY")"

echo "==> Assembling .app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy binary
cp "$UNIVERSAL_BINARY" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$UNIVERSAL_MCP_BINARY" "$APP_BUNDLE/Contents/MacOS/StudioMCP"

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

# Optional native runtime; ordinary builds retain installed-runtime discovery.
if [[ -n "${SGS_POSTGRES_RUNTIME:-}" ]]; then
    python3 "$SCRIPT_DIR/package_postgres_runtime.py" package "$SGS_POSTGRES_RUNTIME" \
        "$APP_BUNDLE/Contents/Resources/PostgreSQL" "${ARCHS[@]}"
fi
if [[ -n "${SGS_POCKET_TTS_RUNTIME:-}" ]]; then
    python3 "$SCRIPT_DIR/package_pocket_tts_runtime.py" package "$SGS_POCKET_TTS_RUNTIME" \
        "$APP_BUNDLE/Contents/Resources/PocketTTSRuntime" "${ARCHS[@]}"
fi

# Strip macOS metadata that breaks codesigning (ignore permission errors from iCloud)
chmod -R u+rw "$APP_BUNDLE" 2>/dev/null || true
xattr -cr "$APP_BUNDLE" 2>/dev/null || true
find "$APP_BUNDLE" -name ".DS_Store" -delete 2>/dev/null || true

sgs_write_metadata "$APP_BUNDLE/Contents/Info.plist"

if [[ -n "$SIGNING_IDENTITY" ]]; then
    if [[ -n "${SGS_POSTGRES_RUNTIME:-}" ]]; then
        python3 "$SCRIPT_DIR/package_postgres_runtime.py" sign \
            "$APP_BUNDLE/Contents/Resources/PostgreSQL" "$SIGNING_IDENTITY"
    fi
    if [[ -n "${SGS_POCKET_TTS_RUNTIME:-}" ]]; then
        python3 "$SCRIPT_DIR/package_pocket_tts_runtime.py" sign \
            "$APP_BUNDLE/Contents/Resources/PocketTTSRuntime" "$SIGNING_IDENTITY"
    fi
    codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP_BUNDLE/Contents/MacOS/StudioMCP"
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
