#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

configuration="${CONFIGURATION:-release}"
swift build -c "$configuration"
binary_dir="$(swift build -c "$configuration" --show-bin-path)"
bundle="$PWD/build/MacClaude.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources" build/AppIcon.iconset
cp "$binary_dir/MacClaude" "$bundle/Contents/MacOS/MacClaude.new"
cp Resources/Info.plist "$bundle/Contents/Info.plist"
cp LICENSE "$bundle/Contents/Resources/LICENSE"
xcrun swift scripts/make-icon.swift build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$bundle/Contents/Resources/AppIcon.icns"
if [[ "$configuration" == "release" ]]; then
  strip -x "$bundle/Contents/MacOS/MacClaude.new"
fi
mv -f "$bundle/Contents/MacOS/MacClaude.new" "$bundle/Contents/MacOS/MacClaude"
if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$bundle"
else
  codesign --force --sign - "$bundle"
fi
codesign --verify --strict "$bundle"
printf 'Built %s\n' "$bundle"
du -sh "$bundle"
