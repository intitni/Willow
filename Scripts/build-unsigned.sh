#!/bin/bash
set -euo pipefail
ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT_DIR"
VERSION=${1:-1.2.1}
BUILD_NUMBER=${2:-5}
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ ! "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
  echo 'Expected version X.Y.Z and a positive numeric build number.' >&2
  exit 1
fi
python3 Scripts/check-release-safety.py
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/willow-release.XXXXXX")
trap 'rm -rf "$WORK_DIR"' EXIT
OUTPUT_DIR="$ROOT_DIR/dist"
mkdir -p "$OUTPUT_DIR"
xcodebuild -project Willow.xcodeproj -scheme Willow -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath "${WILLOW_DERIVED_DATA:-$ROOT_DIR/build/ReleaseDerivedData}" \
  -archivePath "$WORK_DIR/Willow.xcarchive" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= \
  DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= PROVISIONING_PROFILE= \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" archive
python3 Scripts/package-licenses.py --check --source-archive "$OUTPUT_DIR/Willow-${VERSION}-sources.tar.gz"
(cd "$OUTPUT_DIR" && shasum -a 256 "Willow-${VERSION}-sources.tar.gz" > "Willow-${VERSION}-sources.tar.gz.sha256")
mkdir -p "$WORK_DIR/Payload"
ditto --norsrc "$WORK_DIR/Willow.xcarchive/Products/Applications/Willow.app" "$WORK_DIR/Payload/Willow.app"
# 某些工具链可能产生临时 ad-hoc 签名，仅移除暂存副本的签名。
while IFS= read -r -d '' binary; do
  if file -b "$binary" | grep -q 'Mach-O'; then
    if codesign -d "$binary" >/dev/null 2>&1; then
      codesign --remove-signature "$binary"
    fi
  fi
done < <(find "$WORK_DIR/Payload/Willow.app" -type f -print0)
find "$WORK_DIR/Payload/Willow.app" -type d -name _CodeSignature -prune -exec rm -rf {} +
python3 Scripts/check-release-safety.py --app "$WORK_DIR/Payload/Willow.app"
# 仅发布未签名 IPA、对应源码包及校验和，不上传 Xcode archive、日志或工作目录。
IPA="Willow-${VERSION}-unsigned.ipa"
ditto -c -k --norsrc --keepParent "$WORK_DIR/Payload" "$WORK_DIR/$IPA"
mv "$WORK_DIR/$IPA" "$OUTPUT_DIR/$IPA"
(cd "$OUTPUT_DIR" && shasum -a 256 "$IPA" > "$IPA.sha256")
printf 'Built %s\n' "$OUTPUT_DIR/$IPA"
