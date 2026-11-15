#!/bin/sh
set -eu
ROOT_DIR=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$ROOT_DIR"
export WILLOW_PACKAGE_TESTS_ONLY=1
WILLOW_TEST_DIRECTORY=$(mktemp -d /private/tmp/willow-plugin-test.XXXXXX)
trap 'rm -rf "$WILLOW_TEST_DIRECTORY"' EXIT
export WILLOW_PLUGIN_STORAGE_DIRECTORY="$WILLOW_TEST_DIRECTORY/plugins"
export PATH="$HOME/.cargo/bin:$PATH"
export MACOSX_DEPLOYMENT_TARGET=26.0
export RUSTC="$(rustup which --toolchain 1.96.1 rustc)"
sh Scripts/cargo-bridge.sh test --manifest-path Bridge/Cargo.toml --lib --locked
sh Scripts/cargo-bridge.sh build --manifest-path Bridge/Cargo.toml --locked
swift test --disable-sandbox --package-path Core -Xswiftc -disable-sandbox -Xswiftc -DWILLOW_TESTING --filter BreezePluginsTests
