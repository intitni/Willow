#!/bin/sh
set -eu
ROOT_DIR=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
export PATH="$HOME/.cargo/bin:$PATH"
export RUSTC="$(rustup which --toolchain 1.96.1 rustc)"
export IPHONEOS_DEPLOYMENT_TARGET=26.0
case "${PLATFORM_NAME:-iphonesimulator}" in
  iphoneos) TARGET=aarch64-apple-ios; SDK=iphoneos; CLANG_TARGET=arm64-apple-ios26.0 ;;
  iphonesimulator) TARGET=aarch64-apple-ios-sim; SDK=iphonesimulator; CLANG_TARGET=arm64-apple-ios26.0-simulator ;;
  *) echo "Unsupported platform: ${PLATFORM_NAME}" >&2; exit 1 ;;
esac
export SDKROOT="$(xcrun --sdk "$SDK" --show-sdk-path)"
TARGET_KEY=$(echo "$TARGET" | tr '-' '_')
export "BINDGEN_EXTRA_CLANG_ARGS_${TARGET_KEY}=--target=$CLANG_TARGET -isysroot $SDKROOT"
export "CFLAGS_${TARGET_KEY}=-isysroot $SDKROOT -target $CLANG_TARGET"
export CARGO_TARGET_DIR="$ROOT_DIR/Bridge/target"
if [ "${CONFIGURATION:-Debug}" = Release ]; then
  sh "$ROOT_DIR/Scripts/cargo-bridge.sh" build --manifest-path "$ROOT_DIR/Bridge/Cargo.toml" --target "$TARGET" --release --locked
else
  sh "$ROOT_DIR/Scripts/cargo-bridge.sh" build --manifest-path "$ROOT_DIR/Bridge/Cargo.toml" --target "$TARGET" --locked
fi
