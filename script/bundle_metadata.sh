#!/usr/bin/env bash
# Canonical app identity and versions live in the source Info.plist.
SGS_METADATA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SGS_SOURCE_PLIST="$SGS_METADATA_ROOT/Sources/SQLiteGraphStudio/App/Info.plist"

sgs_metadata() {
    /usr/libexec/PlistBuddy -c "Print :$1" "$SGS_SOURCE_PLIST"
}

sgs_write_metadata() {
    cp "$SGS_SOURCE_PLIST" "$1"
    plutil -lint "$1" >/dev/null
}
