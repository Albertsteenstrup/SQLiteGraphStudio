#!/usr/bin/env bash
# Repackage an existing app. This does not sign or notarize the resulting DMG.
# Usage: bash script/create_dmg.sh [app-path] [output-dmg-path]
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${1:-$PROJECT_DIR/dist/SQLiteGraphStudio.app}"
DMG_PATH="${2:-$PROJECT_DIR/dist/SQLiteGraphStudio.dmg}"

if [ ! -d "$APP_PATH" ]; then
    echo "Error: App not found at $APP_PATH" >&2
    exit 1
fi

mkdir -p "$(dirname "$DMG_PATH")"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sgs-dmg.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
cp -R "$APP_PATH" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create \
    -volname "SQLiteGraphStudio" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

echo "Created DMG: $DMG_PATH (container signing and notarization are separate steps)"
