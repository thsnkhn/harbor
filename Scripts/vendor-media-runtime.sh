#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
runtime_dir="${project_dir}/Vendor/MediaRuntime"
host_arch="$(uname -m)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

yt_dlp_version="${YT_DLP_VERSION:-2026.06.09}"
yt_dlp_url="${YT_DLP_URL:-https://github.com/yt-dlp/yt-dlp/releases/download/${yt_dlp_version}/yt-dlp_macos}"
arm64_ffmpeg_path="${ARM64_FFMPEG_PATH:-${FFMPEG_PATH:-$(command -v ffmpeg || true)}}"
arm64_ffprobe_path="${ARM64_FFPROBE_PATH:-${FFPROBE_PATH:-$(command -v ffprobe || true)}}"
x86_64_ffmpeg_version="${X86_64_FFMPEG_VERSION:-8.1.2}"
x86_64_ffmpeg_url="${X86_64_FFMPEG_URL:-https://evermeet.cx/ffmpeg/ffmpeg-${x86_64_ffmpeg_version}.zip}"
x86_64_ffprobe_url="${X86_64_FFPROBE_URL:-https://evermeet.cx/ffmpeg/ffprobe-${x86_64_ffmpeg_version}.zip}"

download_file() {
  local url="$1"
  local output="$2"

  if command -v aria2c >/dev/null 2>&1; then
    aria2c --allow-overwrite=true --dir "$(dirname "$output")" --out "$(basename "$output")" "$url"
  else
    curl --fail --location --silent --show-error "$url" --output "$output"
  fi
}

ensure_yt_dlp_download() {
  local output="${tmp_dir}/yt-dlp"
  if [[ ! -f "$output" ]]; then
    echo "Downloading yt-dlp ${yt_dlp_version}"
    download_file "$yt_dlp_url" "$output"
    chmod 755 "$output"
  fi
}

copy_yt_dlp() {
  local destination="$1"
  ensure_yt_dlp_download
  ditto "${tmp_dir}/yt-dlp" "${destination}/yt-dlp"
  chmod 755 "${destination}/yt-dlp"
  codesign --force --sign - "${destination}/yt-dlp"
}

is_system_dependency() {
  local dependency="$1"
  [[ "$dependency" == /System/* || "$dependency" == /usr/lib/* || "$dependency" == @rpath/* ]]
}

copy_dependency_tree() {
  local binary="$1"
  local queue_file="${tmp_dir}/queue"
  local seen_file="${tmp_dir}/seen"
  : > "$queue_file"
  : > "$seen_file"

  otool -L "$binary" |
    awk 'NR > 1 { print $1 }' |
    while read -r dependency; do
      if [[ -n "$dependency" ]] && ! is_system_dependency "$dependency"; then
        echo "$dependency"
      fi
    done > "$queue_file"

  while [[ -s "$queue_file" ]]; do
    local dependency
    dependency="$(head -n 1 "$queue_file")"
    tail -n +2 "$queue_file" > "${queue_file}.next"
    mv "${queue_file}.next" "$queue_file"

    if grep -Fxq "$dependency" "$seen_file"; then
      continue
    fi
    echo "$dependency" >> "$seen_file"

    if [[ ! -f "$dependency" ]]; then
      echo "Skipping missing dependency: $dependency" >&2
      continue
    fi

    local copied_path="${lib_dir}/$(basename "$dependency")"
    if [[ ! -f "$copied_path" ]]; then
      echo "Copying dependency $(basename "$dependency")"
      ditto "$dependency" "$copied_path"
      chmod 755 "$copied_path"
    fi

    otool -L "$dependency" |
      awk 'NR > 1 { print $1 }' |
      while read -r nested; do
        if [[ -n "$nested" ]] && ! is_system_dependency "$nested"; then
          echo "$nested"
        fi
      done >> "$queue_file"
  done
}

rewrite_load_paths() {
  local target="$1"
  local is_dylib="${2:-false}"

  if [[ "$is_dylib" == "true" ]]; then
    install_name_tool -id "@executable_path/../lib/$(basename "$target")" "$target" || true
  fi

  otool -L "$target" |
    awk 'NR > 1 { print $1 }' |
    while read -r dependency; do
      if [[ -z "$dependency" ]] || is_system_dependency "$dependency"; then
        continue
      fi

      local basename_dependency
      basename_dependency="$(basename "$dependency")"
      if [[ -f "${lib_dir}/${basename_dependency}" ]]; then
        install_name_tool -change "$dependency" "@executable_path/../lib/${basename_dependency}" "$target"
      fi
    done
}

stage_arm64_runtime() {
  local arch="arm64"
  local bin_dir="${runtime_dir}/${arch}/bin"
  local lib_dir="${runtime_dir}/${arch}/lib"

  if [[ -z "$arm64_ffmpeg_path" || ! -x "$arm64_ffmpeg_path" ]]; then
    echo "ffmpeg was not found. Install it with Homebrew or set ARM64_FFMPEG_PATH." >&2
    exit 1
  fi

  if [[ -z "$arm64_ffprobe_path" || ! -x "$arm64_ffprobe_path" ]]; then
    echo "ffprobe was not found. Install it with Homebrew or set ARM64_FFPROBE_PATH." >&2
    exit 1
  fi

  echo "Staging arm64 media runtime from ${arm64_ffmpeg_path}"
  rm -rf "${runtime_dir:?}/${arch}"
  mkdir -p "$bin_dir" "$lib_dir"
  copy_yt_dlp "$bin_dir"

  ditto "$arm64_ffmpeg_path" "${bin_dir}/ffmpeg"
  ditto "$arm64_ffprobe_path" "${bin_dir}/ffprobe"
  chmod 755 "${bin_dir}/ffmpeg" "${bin_dir}/ffprobe"

  copy_dependency_tree "${bin_dir}/ffmpeg"
  copy_dependency_tree "${bin_dir}/ffprobe"

  rewrite_load_paths "${bin_dir}/ffmpeg"
  rewrite_load_paths "${bin_dir}/ffprobe"

  for dylib in "${lib_dir}"/*.dylib; do
    [[ -e "$dylib" ]] || continue
    rewrite_load_paths "$dylib" true
  done

  codesign --force --sign - "${bin_dir}/ffmpeg" "${bin_dir}/ffprobe" "${lib_dir}"/*.dylib
}

stage_x86_64_runtime() {
  local arch="x86_64"
  local bin_dir="${runtime_dir}/${arch}/bin"
  local ffmpeg_zip="${tmp_dir}/ffmpeg-x86_64.zip"
  local ffprobe_zip="${tmp_dir}/ffprobe-x86_64.zip"
  local ffmpeg_extract="${tmp_dir}/ffmpeg-x86_64"
  local ffprobe_extract="${tmp_dir}/ffprobe-x86_64"

  echo "Staging x86_64 media runtime from Evermeet ffmpeg ${x86_64_ffmpeg_version}"
  rm -rf "${runtime_dir:?}/${arch}"
  mkdir -p "$bin_dir" "$ffmpeg_extract" "$ffprobe_extract"
  copy_yt_dlp "$bin_dir"

  download_file "$x86_64_ffmpeg_url" "$ffmpeg_zip"
  download_file "$x86_64_ffprobe_url" "$ffprobe_zip"
  ditto -x -k "$ffmpeg_zip" "$ffmpeg_extract"
  ditto -x -k "$ffprobe_zip" "$ffprobe_extract"

  local ffmpeg_binary
  local ffprobe_binary
  ffmpeg_binary="$(find "$ffmpeg_extract" -type f -name ffmpeg | head -n 1)"
  ffprobe_binary="$(find "$ffprobe_extract" -type f -name ffprobe | head -n 1)"

  if [[ -z "$ffmpeg_binary" || -z "$ffprobe_binary" ]]; then
    echo "Could not locate x86_64 ffmpeg/ffprobe in downloaded archives." >&2
    exit 1
  fi

  ditto "$ffmpeg_binary" "${bin_dir}/ffmpeg"
  ditto "$ffprobe_binary" "${bin_dir}/ffprobe"
  chmod 755 "${bin_dir}/ffmpeg" "${bin_dir}/ffprobe"
  codesign --force --sign - "${bin_dir}/ffmpeg" "${bin_dir}/ffprobe"
}

if [[ "$host_arch" != "arm64" ]]; then
  echo "Host architecture is ${host_arch}; arm64 ffmpeg paths may need ARM64_FFMPEG_PATH/ARM64_FFPROBE_PATH overrides." >&2
fi

stage_arm64_runtime
stage_x86_64_runtime

cat > "${runtime_dir}/README.md" <<EOF
# Bundled Media Runtime

This directory holds Harbor's self-contained media runtime for public media downloads.

- yt-dlp: ${yt_dlp_version}, universal macOS build copied into both architecture folders.
- arm64 ffmpeg/ffprobe: copied from ${arm64_ffmpeg_path%/bin/ffmpeg}
- x86_64 ffmpeg/ffprobe: Evermeet ${x86_64_ffmpeg_version} static macOS builds.

The app launches one yt-dlp process per active media download. yt-dlp may spawn the bundled ffmpeg/ffprobe binaries for probing and merging; Harbor runs the process in its own process group so pause, cancel, and quit terminate the full child tree.

TODO: Add a third-party license manifest to release packaging before public distribution. The bundled ffmpeg build is GPL-enabled.

To refresh this runtime:

\`\`\`bash
./Scripts/vendor-media-runtime.sh
\`\`\`
EOF

echo "Media runtime staged at ${runtime_dir}"
