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
printf '' > "$TORRENT_FILE"

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

echo "Testing .torrent external open..."
open -a "$APP_PATH" "$TORRENT_FILE"
sleep "$SETTLE_SECONDS"
assert_harbor_alive

echo "Testing magnet external open..."
open -a "$APP_PATH" "magnet:?xt=urn:btih:0000000000000000000000000000000000000000&dn=HarborSmoke"
sleep "$SETTLE_SECONDS"
assert_harbor_alive

echo "Release smoke test passed."
