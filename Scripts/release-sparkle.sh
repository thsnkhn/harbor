#!/bin/sh

set -eu

# Release preflight:
# 1. Export the notarized app bundle to build/export/Harbor.app.
# 2. Create a signed annotated tag, for example:
#    git tag -s v1.2.4 -m "Harbor 1.2.4"
# 3. Push the tag and create the matching GitHub release before running this script.

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_NAME="Harbor"
GITHUB_REPO="${GITHUB_REPO:-tahseen-kakar/harbor}"
EXPORT_DIR="$PROJECT_DIR/build/export"
APP_PATH="$EXPORT_DIR/Harbor.app"
OUTPUT_DIR="${OUTPUT_DIR:-$PROJECT_DIR/build/release}"
STAGING_ROOT="${STAGING_ROOT:-$PROJECT_DIR/build/dmg-root}"
PAGES_WORKTREE="${PAGES_WORKTREE:-$PROJECT_DIR/.worktrees/gh-pages}"
PAGES_BRANCH="${PAGES_BRANCH:-gh-pages}"
PAGES_REMOTE="${PAGES_REMOTE:-origin}"
UPDATES_SUBDIR="${UPDATES_SUBDIR:-updates}"
SPARKLE_BIN_DIR="${SPARKLE_BIN_DIR:-}"
DOWNLOAD_URL_PREFIX="${DOWNLOAD_URL_PREFIX:-https://tahseen-kakar.github.io/harbor/$UPDATES_SUBDIR/}"
RELEASE_NOTES_URL_PREFIX="${RELEASE_NOTES_URL_PREFIX:-$DOWNLOAD_URL_PREFIX}"
PUBLIC_FEED_URL="${PUBLIC_FEED_URL:-https://tahseen-kakar.github.io/harbor/appcast.xml}"

if [ ! -d "$APP_PATH" ]; then
  echo "Expected an exported notarized app bundle at: $APP_PATH" >&2
  echo "Export Harbor.app from Xcode Organizer to $EXPORT_DIR first." >&2
  exit 1
fi

if [ -z "$SPARKLE_BIN_DIR" ]; then
  SPARKLE_BIN_DIR="$(find "$HOME/Library/Developer/Xcode/DerivedData" -path '*/SourcePackages/artifacts/sparkle/Sparkle/bin' -type d 2>/dev/null | head -n 1 || true)"
fi

if [ -z "$SPARKLE_BIN_DIR" ] || [ ! -x "$SPARKLE_BIN_DIR/generate_appcast" ]; then
  echo "Sparkle tools not found. Set SPARKLE_BIN_DIR to the directory containing generate_appcast and generate_keys." >&2
  exit 1
fi

case "$DOWNLOAD_URL_PREFIX" in
  */) ;;
  *) DOWNLOAD_URL_PREFIX="$DOWNLOAD_URL_PREFIX/" ;;
esac

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)"

if [ -z "$VERSION" ] || [ -z "$BUILD_NUMBER" ]; then
  echo "Unable to read CFBundleShortVersionString / CFBundleVersion from exported app." >&2
  exit 1
fi

RELEASE_TAG="v$VERSION"
DMG_NAME="$PROJECT_NAME-$VERSION.dmg"
DMG_PATH="$OUTPUT_DIR/$DMG_NAME"
LATEST_DMG_NAME="$PROJECT_NAME.dmg"
LATEST_DMG_PATH="$OUTPUT_DIR/$LATEST_DMG_NAME"

ensure_pages_worktree() {
  mkdir -p "$(dirname "$PAGES_WORKTREE")"

  if [ -e "$PAGES_WORKTREE/.git" ] || [ -d "$PAGES_WORKTREE/.git" ]; then
    return
  fi

  if git show-ref --verify --quiet "refs/heads/$PAGES_BRANCH"; then
    git worktree add "$PAGES_WORKTREE" "$PAGES_BRANCH"
    return
  fi

  if git ls-remote --exit-code --heads "$PAGES_REMOTE" "$PAGES_BRANCH" >/dev/null 2>&1; then
    git worktree add -B "$PAGES_BRANCH" "$PAGES_WORKTREE" "$PAGES_REMOTE/$PAGES_BRANCH"
    return
  fi

  git worktree add --detach "$PAGES_WORKTREE"
  git -C "$PAGES_WORKTREE" switch --orphan "$PAGES_BRANCH"
  find "$PAGES_WORKTREE" -mindepth 1 -maxdepth 1 ! -name '.git' -exec rm -rf {} +
  touch "$PAGES_WORKTREE/.nojekyll"
  git -C "$PAGES_WORKTREE" add .nojekyll
  git -C "$PAGES_WORKTREE" commit -m "Initialize gh-pages"
}

echo "Stapling exported app..."
xcrun stapler staple "$APP_PATH"

echo "Validating stapled app..."
xcrun stapler validate "$APP_PATH"

echo "Checking GitHub release $RELEASE_TAG..."
gh release view "$RELEASE_TAG" --repo "$GITHUB_REPO" >/dev/null

mkdir -p "$OUTPUT_DIR"
rm -rf "$STAGING_ROOT"
mkdir -p "$STAGING_ROOT"

ditto "$APP_PATH" "$STAGING_ROOT/$PROJECT_NAME.app"
ln -s /Applications "$STAGING_ROOT/Applications"
rm -f "$DMG_PATH"

echo "Creating $DMG_NAME from exported app..."
hdiutil create \
  -volname "$PROJECT_NAME" \
  -srcfolder "$STAGING_ROOT" \
  -ov \
  -format UDZO \
  "$DMG_PATH" >/dev/null

ensure_pages_worktree

UPDATES_DIR="$PAGES_WORKTREE/$UPDATES_SUBDIR"
mkdir -p "$UPDATES_DIR"
cp "$DMG_PATH" "$UPDATES_DIR/$DMG_NAME"

echo "Generating Sparkle appcast..."
"$SPARKLE_BIN_DIR/generate_appcast" \
  --download-url-prefix "$DOWNLOAD_URL_PREFIX" \
  --release-notes-url-prefix "$RELEASE_NOTES_URL_PREFIX" \
  -o "$PAGES_WORKTREE/appcast.xml" \
  "$UPDATES_DIR"

touch "$PAGES_WORKTREE/.nojekyll"

echo "Uploading DMG to GitHub release..."
gh release upload "$RELEASE_TAG" "$DMG_PATH" --repo "$GITHUB_REPO" --clobber
cp "$DMG_PATH" "$LATEST_DMG_PATH"
gh release upload "$RELEASE_TAG" "$LATEST_DMG_PATH" --repo "$GITHUB_REPO" --clobber

git -C "$PAGES_WORKTREE" add appcast.xml .nojekyll "$UPDATES_SUBDIR"

if git -C "$PAGES_WORKTREE" diff --cached --quiet; then
  echo "No Sparkle site changes to commit."
else
  git -C "$PAGES_WORKTREE" commit -m "Publish $PROJECT_NAME $VERSION"
  git -C "$PAGES_WORKTREE" push "$PAGES_REMOTE" "$PAGES_BRANCH"
fi

echo "Cleaning up exported app and temporary staging..."
rm -rf "$APP_PATH" "$STAGING_ROOT"

echo
echo "Release publish complete."
echo "Version: $VERSION ($BUILD_NUMBER)"
echo "Feed URL: $PUBLIC_FEED_URL"
echo "DMG: $DMG_PATH"
echo "GitHub Release: https://github.com/$GITHUB_REPO/releases/tag/$RELEASE_TAG"
echo "Pages worktree: $PAGES_WORKTREE"
echo
echo "Private material that must stay off-repo:"
echo "  - Sparkle private EdDSA key"
echo "  - Apple certificate exports (.p12) and passwords"
echo "  - notarytool credentials / app-specific passwords"
