#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="SQLiteGraphStudio"


ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/bundle_metadata.sh"
BUNDLE_ID="$(sgs_metadata CFBundleIdentifier)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
POCKET_TTS_ARCHS=()
POCKET_TTS_REQUIRED="${SGS_POCKET_TTS_RUNTIME_REQUIRED:-0}"
SGS_BUILD_JOBS="${SGS_BUILD_JOBS:-4}"
if [[ ! "$SGS_BUILD_JOBS" =~ ^[1-9][0-9]*$ ]]; then
  echo "SGS_BUILD_JOBS must be a positive integer." >&2
  exit 2
fi
if [[ "$POCKET_TTS_REQUIRED" != "0" && "$POCKET_TTS_REQUIRED" != "1" ]]; then
  echo "SGS_POCKET_TTS_RUNTIME_REQUIRED must be 0 or 1." >&2
  exit 2
fi
if [[ "$POCKET_TTS_REQUIRED" == "1" && -z "${SGS_POCKET_TTS_RUNTIME:-}" ]]; then
  echo "Pocket TTS was required for this build, but SGS_POCKET_TTS_RUNTIME is unset." >&2
  exit 2
fi
if [[ -n "${SGS_POCKET_TTS_RUNTIME:-}" ]]; then
  case "$(uname -m)" in
    arm64) POCKET_TTS_ARCHS=("arm64") ;;
    x86_64) POCKET_TTS_ARCHS=("x86_64") ;;
    *) echo "Pocket TTS packaging does not support this build architecture: $(uname -m)" >&2; exit 2 ;;
  esac
fi

case "$MODE" in
  run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify|--build-only|build-only) ;;
  *) echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--build-only]" >&2; exit 2 ;;
esac

if [[ -n "${SGS_POSTGRES_RUNTIME:-}" ]]; then
  SGS_POSTGRES_RUNTIME="$(python3 "$ROOT_DIR/script/package_postgres_runtime.py" check-source "$SGS_POSTGRES_RUNTIME" "$APP_BUNDLE")"
fi
if [[ -n "${SGS_POCKET_TTS_RUNTIME:-}" ]]; then
  SGS_POCKET_TTS_RUNTIME="$(python3 "$ROOT_DIR/script/package_pocket_tts_runtime.py" check-source \
    "$SGS_POCKET_TTS_RUNTIME" "$APP_BUNDLE" "${POCKET_TTS_ARCHS[@]}")"
fi

sgs_assert_bundle_not_running "$APP_BUNDLE"
cd "$ROOT_DIR"
swift build -j "$SGS_BUILD_JOBS" --product "$APP_NAME"
swift build -j "$SGS_BUILD_JOBS" --product StudioMCP
BUILD_BINARY="$(swift build --show-bin-path)/$APP_NAME"
MCP_BINARY="$(swift build --show-bin-path)/StudioMCP"

sgs_assert_bundle_not_running "$APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS"
mkdir -p "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"
cp "$MCP_BINARY" "$APP_MACOS/StudioMCP"
chmod +x "$APP_MACOS/StudioMCP"

if [ -f "$ROOT_DIR/script/AppIcon.icns" ]; then
  cp "$ROOT_DIR/script/AppIcon.icns" "$APP_RESOURCES/AppIcon.icns"
fi

sgs_write_metadata "$INFO_PLIST"
for bundle in "$(dirname "$BUILD_BINARY")/"*.bundle; do
  if [ -d "$bundle" ]; then
    cp -R "$bundle" "$APP_RESOURCES/"
  fi
done

if [[ -n "${SGS_POSTGRES_RUNTIME:-}" ]]; then
  RUNTIME_ARCHS_TEXT="$(lipo -archs "$BUILD_BINARY")"
  read -r -a RUNTIME_ARCHS <<< "$RUNTIME_ARCHS_TEXT"
  python3 "$ROOT_DIR/script/package_postgres_runtime.py" package "$SGS_POSTGRES_RUNTIME" \
    "$APP_RESOURCES/PostgreSQL" "${RUNTIME_ARCHS[@]}"
fi
if [[ -n "${SGS_POCKET_TTS_RUNTIME:-}" ]]; then
  python3 "$ROOT_DIR/script/package_pocket_tts_runtime.py" package "$SGS_POCKET_TTS_RUNTIME" \
    "$APP_RESOURCES/PocketTTSRuntime" "${POCKET_TTS_ARCHS[@]}"
fi

open_app() {
  sgs_open_reusing_running_app "$APP_BUNDLE"
}

case "$MODE" in
  --build-only|build-only)
    echo "Built for local testing: $APP_BUNDLE"
    ;;
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
