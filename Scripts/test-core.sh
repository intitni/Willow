#!/bin/sh
set -eu
ROOT_DIR=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$ROOT_DIR"
export WILLOW_PACKAGE_TESTS_ONLY=1
export PATH="$HOME/.cargo/bin:$PATH"
export MACOSX_DEPLOYMENT_TARGET=26.0
export RUSTC="$(rustup which --toolchain 1.96.1 rustc)"
cargo +1.96.1 build --manifest-path Bridge/Cargo.toml --locked
swift test --disable-sandbox --package-path Core -Xswiftc -disable-sandbox -Xswiftc -DWILLOW_TESTING --filter CoreStorageTests
