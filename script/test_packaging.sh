#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sgs-packaging-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

python3 "$PROJECT_DIR/Tests/Packaging/test_packaging.py"
swiftc -module-cache-path "$TEST_DIR/module-cache" \
    "$PROJECT_DIR/Sources/StudioCore/App/PreferenceDomainMigration.swift" \
    "$PROJECT_DIR/Tests/Packaging/PreferencesMigrationTests.swift" \
    -o "$TEST_DIR/preferences-tests"
"$TEST_DIR/preferences-tests"
