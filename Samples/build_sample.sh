#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

swift run SampleBuilder "$ROOT_DIR/Samples/small_sample.sqlite" default
swift run SampleBuilder "$ROOT_DIR/Samples/big_sample.sqlite" big
