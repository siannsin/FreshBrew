#!/usr/bin/env bash
set -euo pipefail

APP_NAME="FreshBrew"
PROJECT_NAME="FreshBrew.xcodeproj"
SCHEME_NAME="FreshBrew"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
DERIVED_DATA="$(mktemp -d "${TMPDIR:-/tmp}/freshbrew-release.XXXXXX")"
DMG_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/freshbrew-dmg.XXXXXX")"

cleanup() {
  rm -rf "$DERIVED_DATA" "$DMG_STAGE"
}
trap cleanup EXIT

PROJECT_VERSION="$({
  xcodebuild -project "$ROOT_DIR/$PROJECT_NAME" \
    -scheme "$SCHEME_NAME" \
    -configuration Release \
    -showBuildSettings 2>/dev/null
} | awk '/ MARKETING_VERSION = / { print $3; exit }')"

if [[ -z "$PROJECT_VERSION" ]]; then
  echo "Unable to read MARKETING_VERSION from $PROJECT_NAME." >&2
  exit 1
fi

RELEASE_TAG="${1:-v$PROJECT_VERSION}"
VERSION="${RELEASE_TAG#v}"
if [[ "$RELEASE_TAG" != "v$VERSION" || "$VERSION" != "$PROJECT_VERSION" ]]; then
  echo "Release tag $RELEASE_TAG does not match project version v$PROJECT_VERSION." >&2
  exit 1
fi

OUTPUT_NAME="$APP_NAME-$VERSION-arm64"
APP_BUNDLE="$DERIVED_DATA/Build/Products/Release/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
DMG_PATH="$DIST_DIR/$OUTPUT_NAME.dmg"
CHECKSUM_PATH="$DMG_PATH.sha256"

mkdir -p "$DIST_DIR"
rm -f "$DMG_PATH" "$CHECKSUM_PATH"

xcodebuild build \
  -project "$ROOT_DIR/$PROJECT_NAME" \
  -scheme "$SCHEME_NAME" \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO

if [[ "$(lipo -archs "$APP_BINARY")" != "arm64" ]]; then
  echo "$APP_NAME was not built as an Apple Silicon-only application." >&2
  exit 1
fi

BUILT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_BUNDLE/Contents/Info.plist")"
if [[ "$BUILT_VERSION" != "$VERSION" ]]; then
  echo "Built app version $BUILT_VERSION does not match release version $VERSION." >&2
  exit 1
fi

# Ad-hoc signing preserves bundle integrity but does not provide Developer ID
# trust or notarization. Downloaded releases still require Gatekeeper approval.
codesign --force --sign - --options runtime --timestamp=none "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

ditto "$APP_BUNDLE" "$DMG_STAGE/$APP_NAME.app"
ln -s /Applications "$DMG_STAGE/Applications"

hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$DMG_STAGE" \
  -format UDZO \
  -ov \
  "$DMG_PATH"

hdiutil verify "$DMG_PATH"

(
  cd "$DIST_DIR"
  shasum -a 256 "$(basename "$DMG_PATH")" > "$(basename "$CHECKSUM_PATH")"
)

echo "Created $DMG_PATH"
echo "Created $CHECKSUM_PATH"
