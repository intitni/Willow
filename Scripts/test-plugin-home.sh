#!/bin/sh
set -eu
ROOT_DIR=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$ROOT_DIR"
Scripts/test-plugins.sh
TEST_DIR=$(mktemp -d /private/tmp/willow-home-presentation.XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT
export WILLOW_PLUGIN_STORAGE_DIRECTORY="$TEST_DIR/plugins"
PRODUCTS=Core/.build/out/Products/Debug
export PACKAGE_RESOURCE_BUNDLE_PATH="$ROOT_DIR/$PRODUCTS"
xcrun xcstringstool compile Core/Sources/Core/Resources/Localizable.xcstrings --output-directory "$TEST_DIR"
xcrun swiftc -parse-as-library -package-name core -target arm64-apple-macos26.0 \
    -I "$PRODUCTS" \
    -Xcc -fmodule-map-file=Core/.build/out/Intermediates.noindex/GeneratedModuleMaps/BreezeBridge.modulemap \
    Core/Sources/Core/L10n.swift Tests/PresentationResourceBundle.swift \
    Core/Sources/Core/Presentation/PluginHomeModel.swift Core/Sources/Core/Presentation/ComicDetailModel.swift Core/Sources/Core/Presentation/DiscoverModel.swift Tests/HomePresentationSmoke.swift \
    "$PRODUCTS/CoreToast.o" "$PRODUCTS/BreezePlugins.o" "$PRODUCTS/CoreStorage.o" "$PRODUCTS/BreezeRuntime.o" "$PRODUCTS/BreezeBridge.o" \
    -L Bridge/target/debug -lwillow_bridge -lc++ -lz -framework Security -framework SystemConfiguration \
    -o "$TEST_DIR/HomePresentationSmoke"
"$TEST_DIR/HomePresentationSmoke" "$ROOT_DIR/Core/Tests/BreezePluginsTests/Fixtures/contract.cjs"
