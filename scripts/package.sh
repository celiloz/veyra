#!/bin/bash
set -euo pipefail
version="${1:-0.1.0}"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then echo "Expected semantic version, e.g. 0.1.0" >&2; exit 1; fi
root="$(cd "$(dirname "$0")/.." && pwd)"
out="${VEYRA_OUTPUT_DIR:-$root/dist}"
mkdir -p "$out"
zip="$out/Veyra-$version-universal.zip"
if [[ -e "$zip" ]]; then echo "Refusing to overwrite $zip" >&2; exit 1; fi
stage="$(mktemp -d "${TMPDIR:-/tmp}/veyra-package.XXXXXX")"
xcodebuild -project "$root/Veyra.xcodeproj" -scheme Veyra -configuration Release \
  -derivedDataPath "$stage/DerivedData" ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION=1 build
app="$stage/Veyra.app"
ditto "$stage/DerivedData/Build/Products/Release/Veyra.app" "$app"
if [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]]; then
  codesign --force --sign "$DEVELOPER_ID_APPLICATION" --options runtime --timestamp \
    --entitlements "$root/Veyra/Veyra.entitlements" "$app"
else
  codesign --force --sign - --entitlements "$root/Veyra/Veyra.entitlements" "$app"
  echo "Development package: ad-hoc signed, NOT notarized." >&2
fi
codesign --verify --deep --strict --verbose=2 "$app"
architectures="$(xcrun lipo -archs "$app/Contents/MacOS/Veyra")"
[[ " $architectures " == *" arm64 "* && " $architectures " == *" x86_64 "* ]]
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  if [[ -z "${DEVELOPER_ID_APPLICATION:-}" ]]; then echo "Notarization requires DEVELOPER_ID_APPLICATION" >&2; exit 1; fi
  ditto -c -k --sequesterRsrc --keepParent "$app" "$stage/notarize.zip"
  xcrun notarytool submit "$stage/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$app"
  xcrun stapler validate "$app"
  spctl --assess --type execute --verbose=2 "$app"
fi
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"
shasum -a 256 "$zip" > "$zip.sha256"
echo "$zip"
