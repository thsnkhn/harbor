#!/bin/sh
set -eu
output="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"
intermediate="$DERIVED_FILE_DIR/HarborCLI"
mkdir -p "$output" "$intermediate"
printf 'enum CLIInfo { static let version = "%s" }\n' "$MARKETING_VERSION" > "$intermediate/CLIInfo.swift"
for architecture in $ARCHS; do
  xcrun swiftc -O -target "$architecture-apple-macosx$MACOSX_DEPLOYMENT_TARGET" \
    "$PROJECT_DIR/CLI/main.swift" "$PROJECT_DIR/Harbor/Services/CommandLine/CLIWire.swift" \
    "$intermediate/CLIInfo.swift" -o "$intermediate/harbor-$architecture"
done
set --
for architecture in $ARCHS; do set -- "$@" "$intermediate/harbor-$architecture"; done
xcrun lipo -create "$@" -output "$output/harbor"
if [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
  codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --options runtime --timestamp "$output/harbor"
fi
