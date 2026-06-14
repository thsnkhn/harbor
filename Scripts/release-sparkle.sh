#!/bin/sh

set -eu

# Usage:
#   Scripts/release-sparkle.sh [v1.2.4|1.2.4]
#
# Release preflight:
# 1. Export the notarized app bundle to build/export/Harbor.app.
# 2. Run this script with the exported app's version, or omit the argument to use
#    CFBundleShortVersionString from the exported app.

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_NAME="Harbor"
GITHUB_REPO="${GITHUB_REPO:-tahseen-kakar/harbor}"
TAG_REMOTE="${TAG_REMOTE:-origin}"
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
MAXIMUM_DELTAS="${MAXIMUM_DELTAS:-0}"
RUN_RELEASE_SMOKE="${RUN_RELEASE_SMOKE:-YES}"

usage() {
  echo "Usage: $0 [v<version>|<version>]" >&2
}

normalize_release_tag() {
  case "$1" in
    v*) printf '%s\n' "$1" ;;
    *) printf 'v%s\n' "$1" ;;
  esac
}

tag_exists_locally() {
  git rev-parse --verify --quiet "refs/tags/$1" >/dev/null
}

tag_exists_remotely() {
  git ls-remote --exit-code --tags "$TAG_REMOTE" "refs/tags/$1" >/dev/null 2>&1
}

remote_tag_commit() {
  REMOTE_TAG_COMMIT="$(git ls-remote --tags "$TAG_REMOTE" "refs/tags/$1^{}" | sed -n '1s/[[:space:]].*//p')"

  if [ -z "$REMOTE_TAG_COMMIT" ]; then
    REMOTE_TAG_COMMIT="$(git ls-remote --tags "$TAG_REMOTE" "refs/tags/$1" | sed -n '1s/[[:space:]].*//p')"
  fi

  printf '%s\n' "$REMOTE_TAG_COMMIT"
}

ensure_release_tag() {
  if tag_exists_locally "$RELEASE_TAG"; then
    echo "Git tag $RELEASE_TAG already exists locally."
  elif tag_exists_remotely "$RELEASE_TAG"; then
    echo "Fetching existing remote tag $RELEASE_TAG..."
    git fetch "$TAG_REMOTE" "refs/tags/$RELEASE_TAG:refs/tags/$RELEASE_TAG"
  else
    echo "Creating signed Git tag $RELEASE_TAG..."
    git tag -s "$RELEASE_TAG" -m "$PROJECT_NAME $VERSION"
  fi

  if tag_exists_remotely "$RELEASE_TAG"; then
    echo "Git tag $RELEASE_TAG already exists on $TAG_REMOTE."
  else
    echo "Pushing Git tag $RELEASE_TAG to $TAG_REMOTE..."
    git push "$TAG_REMOTE" "$RELEASE_TAG"
  fi

  TAG_COMMIT="$(git rev-list -n 1 "$RELEASE_TAG")"
  HEAD_COMMIT="$(git rev-parse HEAD)"

  if [ "$TAG_COMMIT" != "$HEAD_COMMIT" ]; then
    echo "Git tag $RELEASE_TAG points to $TAG_COMMIT, but HEAD is $HEAD_COMMIT." >&2
    echo "Check out the tagged commit or choose a new release tag before publishing." >&2
    exit 1
  fi

  REMOTE_TAG_COMMIT="$(remote_tag_commit "$RELEASE_TAG")"

  if [ "$REMOTE_TAG_COMMIT" != "$HEAD_COMMIT" ]; then
    echo "Remote Git tag $RELEASE_TAG on $TAG_REMOTE points to $REMOTE_TAG_COMMIT, but HEAD is $HEAD_COMMIT." >&2
    echo "Fix the remote tag or choose a new release tag before publishing." >&2
    exit 1
  fi
}

ensure_github_release() {
  if gh release view "$RELEASE_TAG" --repo "$GITHUB_REPO" >/dev/null 2>&1; then
    echo "GitHub release $RELEASE_TAG already exists."
    return
  fi

  echo "Creating GitHub release $RELEASE_TAG..."
  RELEASE_TITLE="${RELEASE_TITLE:-$PROJECT_NAME $VERSION}"
  RELEASE_NOTES="${RELEASE_NOTES:-$PROJECT_NAME $VERSION}"
  gh release create "$RELEASE_TAG" \
    --repo "$GITHUB_REPO" \
    --verify-tag \
    --title "$RELEASE_TITLE" \
    --notes "$RELEASE_NOTES"
}

if [ "$#" -gt 1 ]; then
  usage
  exit 1
fi

REQUESTED_TAG="${1:-}"

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

if [ -n "$REQUESTED_TAG" ]; then
  RELEASE_TAG="$(normalize_release_tag "$REQUESTED_TAG")"
  REQUESTED_VERSION="${RELEASE_TAG#v}"

  if [ "$REQUESTED_VERSION" != "$VERSION" ]; then
    echo "Requested release tag $RELEASE_TAG does not match exported app version $VERSION." >&2
    exit 1
  fi
else
  RELEASE_TAG="v$VERSION"
fi

DMG_NAME="$PROJECT_NAME-$VERSION.dmg"
DMG_PATH="$OUTPUT_DIR/$DMG_NAME"
LATEST_DMG_NAME="$PROJECT_NAME.dmg"
LATEST_DMG_PATH="$OUTPUT_DIR/$LATEST_DMG_NAME"

if [ "$RUN_RELEASE_SMOKE" != "NO" ]; then
  echo "Running release smoke test..."
  sh "$PROJECT_DIR/Scripts/smoke-release.sh" "$APP_PATH"
fi

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

staple_sparkle_bundle() {
  SPARKLE_BUNDLE_PATH="$1"

  if [ ! -e "$SPARKLE_BUNDLE_PATH" ]; then
    return
  fi

  echo "Stapling nested Sparkle bundle: ${SPARKLE_BUNDLE_PATH#$APP_PATH/}"
  xcrun stapler staple "$SPARKLE_BUNDLE_PATH"
}

staple_sparkle_helpers() {
  SPARKLE_FRAMEWORK_PATH="$APP_PATH/Contents/Frameworks/Sparkle.framework/Versions/Current"

  if [ ! -e "$SPARKLE_FRAMEWORK_PATH" ]; then
    return
  fi

  staple_sparkle_bundle "$SPARKLE_FRAMEWORK_PATH/Updater.app"
  staple_sparkle_bundle "$SPARKLE_FRAMEWORK_PATH/XPCServices/Downloader.xpc"
  staple_sparkle_bundle "$SPARKLE_FRAMEWORK_PATH/XPCServices/Installer.xpc"
}

echo "Stapling exported app..."
xcrun stapler staple "$APP_PATH"

echo "Validating stapled app..."
xcrun stapler validate "$APP_PATH"

staple_sparkle_helpers

echo "Validating app after stapling nested Sparkle bundles..."
xcrun stapler validate "$APP_PATH"
codesign --verify --deep --strict --verbose=4 "$APP_PATH"

ensure_release_tag
ensure_github_release

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
  --maximum-deltas "$MAXIMUM_DELTAS" \
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
