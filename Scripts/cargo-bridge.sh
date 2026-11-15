#!/bin/sh
set -eu
ROOT_DIR=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
override=$(python3 "$ROOT_DIR/Scripts/prepare-breeze-runtime.py")
exec cargo +1.96.1 --config "$override" "$@"
