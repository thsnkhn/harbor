#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="${TMPDIR:-/tmp}/harbor-media-tests"
module_cache="${build_dir}/ModuleCache"
binary="${build_dir}/MediaRuntimeSmokeTests"
media_runtime_root="${project_dir}/Vendor/MediaRuntime"
torrent_runtime_root="${project_dir}/Vendor/TorrentRuntime"

rm -rf "$build_dir"
mkdir -p "$build_dir" "$module_cache"

swiftc \
  -module-cache-path "$module_cache" \
  "${project_dir}/Harbor/Models/MediaDownloadMetadata.swift" \
  "${project_dir}/Harbor/Services/ManagedChildProcess.swift" \
  "${project_dir}/Harbor/Services/MediaRuntimeResolver.swift" \
  "${project_dir}/Harbor/Services/MediaDownloadService.swift" \
  "${project_dir}/Tests/MediaRuntimeSmokeTests.swift" \
  -o "$binary"

"$binary"

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
  check_executable "${media_bin}/ffmpeg"
  check_executable "${media_bin}/ffprobe"
  check_executable "${torrent_bin}/aria2c"

  run_for_arch "$architecture" "${media_bin}/yt-dlp" --version >/dev/null
  run_for_arch "$architecture" "${media_bin}/ffmpeg" -version >/dev/null
  run_for_arch "$architecture" "${media_bin}/ffprobe" -version >/dev/null
  run_for_arch "$architecture" "${torrent_bin}/aria2c" --version >/dev/null
done

echo "Vendored media and torrent runtime binaries launched successfully"
