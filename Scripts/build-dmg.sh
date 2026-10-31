#!/bin/sh

set -eu

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_PATH="$PROJECT_DIR/Harbor.xcodeproj"
SCHEME="Harbor"
CONFIGURATION="${CONFIGURATION:-Release}"
DERIVED_DATA_PATH="$PROJECT_DIR/build/HarborDerivedData"
STAGING_ROOT="${STAGING_ROOT:-$PROJECT_DIR/build/dmg-root}"
OUTPUT_DIR="${OUTPUT_DIR:-$PROJECT_DIR/build/release}"
CODE_SIGNING_ALLOWED="${CODE_SIGNING_ALLOWED:-NO}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-}"
SIGN_TORRENT_RUNTIME="${SIGN_TORRENT_RUNTIME:-YES}"
APP_NAME="Harbor.app"
APP_PATH="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/$APP_NAME"
BUILD_ARCH="${HARBOR_BUILD_ARCH:-$(uname -m)}"
case "$BUILD_ARCH" in
  arm64) PACKAGE_LABEL="Apple-Silicon" ;;
  x86_64) PACKAGE_LABEL="Intel" ;;
  *) echo "Unsupported architecture: $BUILD_ARCH" >&2; exit 1 ;;
esac

sign_path() {
  target_path="$1"

  if [ -z "$SIGNING_IDENTITY" ]; then
    return
  fi

  /usr/bin/codesign \
    --force \
    --timestamp \
    --options runtime \
    --sign "$SIGNING_IDENTITY" \
    "$target_path"
}

echo "Building $APP_NAME ($CONFIGURATION, $BUILD_ARCH)..."
# Keep one unpacked app and one set of compiler outputs between processor builds.
rm -rf "$DERIVED_DATA_PATH/Build" "$STAGING_ROOT"
set -- xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    -destination 'generic/platform=macOS' \
    ARCHS="$BUILD_ARCH" ONLY_ACTIVE_ARCH=NO \
    HARBOR_RUNTIME_ARCHITECTURES="$BUILD_ARCH" \
    CODE_SIGNING_ALLOWED="$CODE_SIGNING_ALLOWED" \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO
if [ -n "${HARBOR_BUILD_NUMBER:-}" ]; then
  set -- "$@" CURRENT_PROJECT_VERSION="$HARBOR_BUILD_NUMBER"
fi
if [ -n "$SIGNING_IDENTITY" ]; then
  set -- "$@" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM"
fi
"$@" build

if [ ! -d "$APP_PATH" ]; then
  echo "Expected app bundle not found at $APP_PATH" >&2
  exit 1
fi

if [ -n "$SIGNING_IDENTITY" ]; then
  SPARKLE_DIR="$APP_PATH/Contents/Frameworks/Sparkle.framework/Versions/B"
  for nested in \
    "$SPARKLE_DIR/Autoupdate" \
    "$SPARKLE_DIR/Updater.app" \
    "$SPARKLE_DIR/XPCServices/Downloader.xpc" \
    "$SPARKLE_DIR/XPCServices/Installer.xpc" \
    "$SPARKLE_DIR" \
    "$APP_PATH/Contents/PlugIns/HarborSafariExtension.appex" \
    "$APP_PATH"; do
    /usr/bin/codesign --force --sign "$SIGNING_IDENTITY" --options runtime \
      --timestamp --preserve-metadata=entitlements "$nested"
  done
fi

if [ "$(lipo -archs "$APP_PATH/Contents/MacOS/Harbor")" != "$BUILD_ARCH" ] ||
   [ "$(lipo -archs "$APP_PATH/Contents/PlugIns/HarborSafariExtension.appex/Contents/MacOS/HarborSafariExtension")" != "$BUILD_ARCH" ]; then
  echo "The app or Safari extension contains the wrong processor build." >&2
  exit 1
fi

if [ -n "$SIGNING_IDENTITY" ] && [ "$SIGN_TORRENT_RUNTIME" = "YES" ]; then
  echo "Signing bundled torrent runtime..."

  find "$APP_PATH/Contents/Resources/TorrentRuntime" \
    -type f \
    \( -name "*.dylib" -o -perm -111 \) \
    | sort \
    | while IFS= read -r runtime_file; do
        sign_path "$runtime_file"
      done

  echo "Re-signing app bundle..."
  sign_path "$APP_PATH"

  echo "Verifying signature..."
  /usr/bin/codesign --verify --verbose=2 "$APP_PATH"
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo "0.0")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Contents/Info.plist")"
echo "App version: $VERSION ($BUILD_NUMBER)"
DMG_NAME="Harbor-${VERSION}-${PACKAGE_LABEL}.dmg"
DMG_PATH="$OUTPUT_DIR/$DMG_NAME"

echo "Preparing DMG staging folder..."
rm -rf "$STAGING_ROOT"
mkdir -p "$STAGING_ROOT" "$OUTPUT_DIR"

ditto "$APP_PATH" "$STAGING_ROOT/$APP_NAME"
ln -s /Applications "$STAGING_ROOT/Applications"

rm -f "$DMG_PATH"

echo "Creating disk image..."
hdiutil create \
  -volname "Harbor" \
  -srcfolder "$STAGING_ROOT" \
  -ov \
  -format UDZO \
  "$DMG_PATH" >/dev/null

if [ -n "$SIGNING_IDENTITY" ]; then
  /usr/bin/codesign --force --sign "$SIGNING_IDENTITY" --timestamp "$DMG_PATH"
  /usr/bin/codesign --verify --strict --verbose=2 "$DMG_PATH"
fi

rm -rf "$STAGING_ROOT"

echo
echo "Created:"
echo "  $DMG_PATH"
echo
echo "When users open this DMG, they'll see Harbor.app and an Applications shortcut for drag-to-install."
if [ -n "$SIGNING_IDENTITY" ]; then
  echo "Signed with:"
  echo "  $SIGNING_IDENTITY"
  echo "Notarize and staple the signed DMG before public distribution."
else
  echo "For public distribution, sign the app and DMG. Then notarize and staple the DMG."
fi
