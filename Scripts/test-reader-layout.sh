#!/bin/sh
set -eu
ROOT_DIR=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$ROOT_DIR"
TEST_DIR=$(mktemp -d /private/tmp/willow-reader-layout.XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun swiftc -parse-as-library Core/Sources/Core/Presentation/ReaderLayout.swift Tests/ReaderLayoutSmoke.swift -o "$TEST_DIR/ReaderLayoutSmoke"
"$TEST_DIR/ReaderLayoutSmoke"
