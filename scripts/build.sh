#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

configuration="${CONFIGURATION:-release}"
swift build -c "$configuration"
binary_dir="$(swift build -c "$configuration" --show-bin-path)"
bundle="$PWD/build/MacClaude.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$binary_dir/MacClaude" "$bundle/Contents/MacOS/MacClaude.new"
cp Resources/Info.plist "$bundle/Contents/Info.plist"
cp LICENSE "$bundle/Contents/Resources/LICENSE"
# SwiftPM resources must travel with the executable, including outside this checkout.
resource_bundle="$binary_dir/MacClaude_MacClaude.bundle"
ditto "$resource_bundle" "$bundle/Contents/Resources/MacClaude_MacClaude.bundle"
# Icon Composer is supported by Xcode 26+. Older Xcodes retain the exported
# compatibility icon. Remove a previous catalog when rebuilding with an older SDK.
rm -f "$bundle/Contents/Resources/Assets.car"
xcode_major="$(xcodebuild -version | awk '/^Xcode / {split($2, v, "."); print v[1]}')"
if [[ "$xcode_major" -ge 26 ]]; then
  xcrun actool Resources/AppIcon.icon --compile "$bundle/Contents/Resources" \
    --platform macosx --minimum-deployment-target 14.0 --app-icon AppIcon \
    --output-partial-info-plist build/icon-info.plist --output-format human-readable-text
  /usr/libexec/PlistBuddy -c 'Merge build/icon-info.plist' "$bundle/Contents/Info.plist"
else
  printf '%s\n' 'Using the exported compatibility icon (Xcode 26+ enables the layered icon).'
fi
# Keep a complete 16–1024px fallback; actool may emit only small legacy renditions.
cp Resources/Brand/AppIcon.icns "$bundle/Contents/Resources/AppIcon.icns"
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
