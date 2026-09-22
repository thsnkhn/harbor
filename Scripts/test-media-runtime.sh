#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
media_runtime_root="${project_dir}/Vendor/MediaRuntime"
torrent_runtime_root="${project_dir}/Vendor/TorrentRuntime"

run_for_arch() {
  local architecture="$1"
  shift

  if /usr/bin/arch "-${architecture}" /usr/bin/true >/dev/null 2>&1; then
    echo "Launching ${architecture}: $(basename "$1")" >&2
    /usr/bin/arch "-${architecture}" "$@"
  else
    echo "Skipping ${architecture} launch check because this Mac cannot run it."
  fi
}

check_executable() {
  local path="$1"
  if [[ ! -x "$path" ]]; then
    echo "Missing executable: $path" >&2
    exit 1
  fi
}

for architecture in arm64 x86_64; do
  media_bin="${media_runtime_root}/${architecture}/bin"
  torrent_bin="${torrent_runtime_root}/${architecture}/bin"

  check_executable "${media_bin}/yt-dlp"
  check_executable "${media_bin}/deno"
  check_executable "${media_bin}/ffmpeg"
  check_executable "${media_bin}/ffprobe"
  check_executable "${torrent_bin}/aria2-next"

  run_for_arch "$architecture" "${media_bin}/yt-dlp" --version >/dev/null
  run_for_arch "$architecture" "${media_bin}/deno" --version >/dev/null
  runtime_report="$(run_for_arch "$architecture" "${media_bin}/yt-dlp" --ignore-config --verbose --js-runtimes "deno:${media_bin}/deno" --simulate about:blank 2>&1 || true)"
  if [[ "$runtime_report" != *"JS runtimes: deno-"* ]]; then
    echo "yt-dlp did not detect bundled Deno for ${architecture}." >&2
    echo "$runtime_report" >&2
    exit 1
  fi
  run_for_arch "$architecture" "${media_bin}/ffmpeg" -version >/dev/null
  run_for_arch "$architecture" "${media_bin}/ffprobe" -version >/dev/null
  run_for_arch "$architecture" "${torrent_bin}/aria2-next" --version >/dev/null
done

echo "Vendored media and torrent runtime binaries launched successfully"
