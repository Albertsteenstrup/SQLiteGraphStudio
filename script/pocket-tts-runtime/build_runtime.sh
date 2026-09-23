#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ "$#" -eq 1 ]; then
  ARCH="$(uname -m)"
  OUTPUT_ARG="$1"
elif [ "$#" -eq 3 ] && [ "$1" = "--architecture" ]; then
  ARCH="$2"
  OUTPUT_ARG="$3"
else
  echo "Usage: $0 [--architecture arm64|x86_64] /absolute/path/to/runtime-output" >&2
  exit 2
fi
case "$ARCH" in
  arm64)
    PYTHON_TRIPLE="aarch64-apple-darwin"
    PYTHON_SHA256="9a1e9e06175c10efd8378b904b07fa21bd791ab3345d7cdffeb4a76c9ff55903"
    ;;
  x86_64)
    echo "Cannot build an Intel Pocket TTS runtime: the locked upstream PyTorch wheel has no macOS x86_64 artifact. Intel builds use the built-in macOS speech provider." >&2
    exit 2
    ;;
  *)
    echo "Pocket TTS runtime build requires macOS arm64 or x86_64; found $ARCH" >&2
    exit 2
    ;;
esac

OUTPUT="$(mkdir -p "$(dirname "$OUTPUT_ARG")" && cd "$(dirname "$OUTPUT_ARG")" && pwd)/$(basename "$OUTPUT_ARG")"
if [ -e "$OUTPUT" ]; then
  echo "Runtime destination already exists: $OUTPUT" >&2
  exit 2
fi

UV="${UV:-uv}"
UV_VERSION="$("$UV" --version)"
case "$UV_VERSION" in
  "uv 0.11.31 "*) ;;
  *)
    echo "Expected uv 0.11.31 for the pinned release build, found: $UV_VERSION" >&2
    exit 2
    ;;
esac

PYTHON_RELEASE="20260718"
PYTHON_VERSION="3.12.13"
PYTHON_ARCHIVE="cpython-${PYTHON_VERSION}+${PYTHON_RELEASE}-${PYTHON_TRIPLE}-install_only_stripped.tar.gz"
PYTHON_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PYTHON_RELEASE}/${PYTHON_ARCHIVE//+/%2B}"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/sgs-pocket-tts.XXXXXX")"
trap 'rm -rf "$TEMP_ROOT"' EXIT

curl --fail --location --retry 2 "$PYTHON_URL" -o "$TEMP_ROOT/$PYTHON_ARCHIVE"
ACTUAL_PYTHON_SHA256="$(shasum -a 256 "$TEMP_ROOT/$PYTHON_ARCHIVE" | awk '{print $1}')"
if [ "$ACTUAL_PYTHON_SHA256" != "$PYTHON_SHA256" ]; then
  echo "Python archive SHA-256 mismatch: expected $PYTHON_SHA256, got $ACTUAL_PYTHON_SHA256" >&2
  exit 2
fi

mkdir -p "$OUTPUT"
tar -xzf "$TEMP_ROOT/$PYTHON_ARCHIVE" -C "$OUTPUT"
if [ ! -x "$OUTPUT/python/bin/python3" ]; then
  echo "Official Python archive did not contain python/bin/python3" >&2
  exit 2
fi

"$UV" pip install \
  --python "$OUTPUT/python/bin/python3" \
  --system \
  --require-hashes \
  --only-binary=:all: \
  --no-cache \
  --requirements "$SCRIPT_DIR/requirements.lock"

EXPECTED_PYTHON_ARCH="$ARCH" \
PYTHONPATH="$OUTPUT/python/lib/python3.12/site-packages" \
  "$OUTPUT/python/bin/python3" -c \
  'import os, platform, pocket_tts, yaml; from importlib.metadata import version; assert platform.machine() == os.environ["EXPECTED_PYTHON_ARCH"]; assert version("pocket-tts") == "3.1.0"; print("Pocket TTS", version("pocket-tts"), "Python", platform.python_version(), platform.machine())'

cp "$SCRIPT_DIR/THIRD_PARTY_NOTICES.md" "$OUTPUT/THIRD_PARTY_NOTICES.md"
cp "$SCRIPT_DIR/requirements.lock" "$OUTPUT/requirements.lock"
LOCK_SHA256="$(shasum -a 256 "$SCRIPT_DIR/requirements.lock" | awk '{print $1}')"
PYTHON_EXECUTABLE_SHA256="$(shasum -a 256 "$OUTPUT/python/bin/python3.12" | awk '{print $1}')"
PYTHON_MINOR="${PYTHON_VERSION%.*}"
cat > "$OUTPUT/runtime-manifest.json" <<EOF
{
  "schema_version": 1,
  "python_minor": "$PYTHON_MINOR",
  "python_version": "$PYTHON_VERSION",
  "python_distribution": "astral-sh/python-build-standalone/$PYTHON_RELEASE",
  "python_distribution_url": "$PYTHON_URL",
  "python_distribution_sha256": "$PYTHON_SHA256",
  "python_executable_sha256": "$PYTHON_EXECUTABLE_SHA256",
  "pocket_tts_version": "3.1.0",
  "protocol_version": 1,
  "requirements_lock_sha256": "$LOCK_SHA256",
  "architectures": ["$ARCH"]
}
EOF

echo "Prepared Pocket TTS runtime at $OUTPUT"
