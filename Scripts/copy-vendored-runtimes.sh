#!/bin/sh
set -eu

# Release builds copy one processor's tools. Universal builds retain both.
runtime_architectures="${HARBOR_RUNTIME_ARCHITECTURES:-arm64 x86_64}"
for architecture in $runtime_architectures; do
  case "$architecture" in
    arm64|x86_64) ;;
    *) echo "Unsupported runtime architecture: $architecture" >&2; exit 1 ;;
  esac
done

for runtime in TorrentRuntime MediaRuntime VPNRuntime; do
  source_dir="$PROJECT_DIR/Vendor/$runtime"
  destination_dir="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/$runtime"
  rm -rf "$destination_dir"
  mkdir -p "$destination_dir"
  for architecture in $runtime_architectures; do
    ditto "$source_dir/$architecture" "$destination_dir/$architecture"
  done
  if [ -d "$source_dir/bin" ]; then
    # yt-dlp is shared by symlinks in the processor directories. Do not thin its PyInstaller payload.
    ditto "$source_dir/bin" "$destination_dir/bin"
  fi
  if [ -f "$source_dir/README.md" ]; then
    cp "$source_dir/README.md" "$destination_dir/README.md"
  fi
done
