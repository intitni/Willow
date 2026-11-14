#!/bin/sh
set -eu
ROOT_DIR=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$ROOT_DIR"
# Build the package dependencies with Xcode's SwiftPM backend first.
Scripts/test-core.sh
TEST_DIR=$(mktemp -d /private/tmp/willow-library-presentation.XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT
PRODUCTS=Core/.build/out/Products/Debug
export PACKAGE_RESOURCE_BUNDLE_PATH="$ROOT_DIR/$PRODUCTS"
xcrun xcstringstool compile Core/Sources/Core/Resources/Localizable.xcstrings --output-directory "$TEST_DIR"
xcrun swiftc -parse-as-library -package-name core -target arm64-apple-macos26.0 \
    -I "$PRODUCTS" \
    -Xcc -fmodule-map-file=Core/.build/out/Intermediates.noindex/GeneratedModuleMaps/BreezeBridge.modulemap \
    Core/Sources/Core/L10n.swift Tests/PresentationResourceBundle.swift \
    Core/Sources/Core/Presentation/LibraryModel.swift Core/Sources/Core/Presentation/DownloadsModel.swift Tests/LibraryPresentationSmoke.swift \
    "$PRODUCTS/BreezePlugins.o" "$PRODUCTS/CoreStorage.o" "$PRODUCTS/BreezeRuntime.o" "$PRODUCTS/BreezeBridge.o" \
    -L Bridge/target/debug -lwillow_bridge -lc++ -lz -framework Security -framework SystemConfiguration \
    -o "$TEST_DIR/LibraryPresentationSmoke"
"$TEST_DIR/LibraryPresentationSmoke"
