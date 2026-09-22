#!/bin/sh

set -eu

# Launches a disposable Harbor.app and sends the external open events that have
# caused toolbar crashes before. Requires an explicit confirmation that the real
# app is not running so user downloads are not touched.

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${1:-${APP_PATH:-$PROJECT_DIR/build/export/Harbor.app}}"
WAIT_SECONDS="${WAIT_SECONDS:-12}"
SETTLE_SECONDS="${SETTLE_SECONDS:-4}"

case "$APP_PATH" in
  /*) ;;
  *) APP_PATH="$PROJECT_DIR/$APP_PATH" ;;
esac

if [ ! -d "$APP_PATH" ]; then
  echo "Expected app bundle at: $APP_PATH" >&2
  exit 1
fi

if [ "${HARBOR_SMOKE_CONFIRM_NO_RUNNING_HARBOR:-NO}" != "YES" ]; then
  echo "Quit Harbor first, then rerun with HARBOR_SMOKE_CONFIRM_NO_RUNNING_HARBOR=YES." >&2
  exit 2
fi

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/harbor-smoke.XXXXXX")"
APP_SUPPORT_DIR="$TMP_ROOT/ApplicationSupport"
DOWNLOAD_DIR="$TMP_ROOT/Downloads"
TORRENT_FILE="$TMP_ROOT/smoke.torrent"
OPEN_WAIT_PID=""

cleanup() {
  status="$?"

  if [ -n "$OPEN_WAIT_PID" ]; then
    pkill -x Harbor >/dev/null 2>&1 || true
    wait "$OPEN_WAIT_PID" >/dev/null 2>&1 || true
  fi

  rm -rf "$TMP_ROOT"
  exit "$status"
}

trap cleanup EXIT INT TERM

mkdir -p "$APP_SUPPORT_DIR" "$DOWNLOAD_DIR"
# A valid two-file torrent reaches the same import and sheet path used by the
# selective-download preview. Keep this fixture self-contained and offline.
printf '%s' 'd4:infod5:filesld6:lengthi7e4:pathl8:Docs.txteed6:lengthi11e4:pathl9:Video.mp4eee4:name11:HarborSmoke12:piece lengthi16384e6:pieces20:11111111111111111111ee' > "$TORRENT_FILE"

assert_harbor_alive() {
  if ! kill -0 "$OPEN_WAIT_PID" >/dev/null 2>&1; then
    echo "Harbor exited during release smoke test." >&2
    exit 1
  fi
}

echo "Launching disposable Harbor from $APP_PATH..."
open -nW "$APP_PATH" --args \
  --harbor-application-support-directory "$APP_SUPPORT_DIR" \
  -defaultDestinationPath "$DOWNLOAD_DIR" \
  -startDownloadsAutomatically NO \
  -notificationsEnabled NO &
OPEN_WAIT_PID="$!"

sleep "$WAIT_SECONDS"
assert_harbor_alive

MEDIA_ARCH="$(uname -m)"
YTDLP_PATH="$APP_PATH/Contents/Resources/MediaRuntime/$MEDIA_ARCH/bin/yt-dlp"
DENO_PATH="$APP_PATH/Contents/Resources/MediaRuntime/$MEDIA_ARCH/bin/deno"
ARIA2_PATH="$APP_PATH/Contents/Resources/TorrentRuntime/$MEDIA_ARCH/bin/aria2-next"

if [ -x "$YTDLP_PATH" ]; then
  echo "Testing bundled yt-dlp helper..."
  "$YTDLP_PATH" --version >/dev/null
else
  echo "Expected bundled yt-dlp helper at: $YTDLP_PATH" >&2
  exit 1
fi

if [ -x "$DENO_PATH" ]; then
  echo "Testing bundled Deno helper..."
  "$DENO_PATH" --version >/dev/null
else
  echo "Expected bundled Deno helper at: $DENO_PATH" >&2
  exit 1
fi

if [ -x "$ARIA2_PATH" ]; then
  echo "Testing bundled Aria2 Next helper and torrent fixture..."
  "$ARIA2_PATH" --version >/dev/null
  "$ARIA2_PATH" --show-files "$TORRENT_FILE" >/dev/null
else
  echo "Expected bundled Aria2 Next helper at: $ARIA2_PATH" >&2
  exit 1
fi

echo "Testing .torrent external open..."
open -a "$APP_PATH" "$TORRENT_FILE"
sleep "$SETTLE_SECONDS"
assert_harbor_alive

echo "Testing magnet external open..."
open -a "$APP_PATH" "magnet:?xt=urn:btih:0000000000000000000000000000000000000000&dn=HarborSmoke"
sleep "$SETTLE_SECONDS"
assert_harbor_alive

echo "Release smoke test passed."
