#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

developer_dir="$(xcode-select -p)"
composer="$developer_dir/../Applications/Icon Composer.app/Contents/Executables/ictool"
if [[ ! -x "$composer" ]]; then
  printf '%s\n' 'Brand exports require Xcode 26+ with Icon Composer.' >&2
  exit 1
fi
mkdir -p build/icon-preview Resources/Brand
# The document owns its copy; keep it synchronized with the in-app illustration.
cp Sources/MacClaude/Resources/FoxPilot.png Resources/AppIcon.icon/Assets/FoxPilot.png
"$composer" "$PWD/Resources/AppIcon.icon" --export-image \
  --output-file "$PWD/docs/images/macclaude-icon.png" \
  --platform macOS --rendition Default --width 512 --height 512 --scale 2
"$composer" "$PWD/Resources/AppIcon.icon" --export-image \
  --output-file "$PWD/Resources/Brand/AppIcon-Dark.png" \
  --platform macOS --rendition Dark --width 512 --height 512 --scale 2
"$composer" "$PWD/Resources/AppIcon.icon" --export-image \
  --output-file "$PWD/Resources/Brand/AppIcon-Tinted.png" \
  --platform macOS --rendition TintedDark --width 512 --height 512 --scale 2 \
  --tint-color 0.08 --tint-strength 0.5
xcrun swiftc -module-cache-path build/module-cache Sources/MacClaude/FoxMark.swift \
  scripts/BrandExport.swift -o build/export-brand
build/export-brand "$PWD"
iconutil -c icns build/icon-preview/AppIcon.iconset -o Resources/Brand/AppIcon.icns
kit="$PWD/build/MacClaude-Brand-Kit"
mkdir -p "$kit"
ditto Resources/Brand "$kit/Exports"
ditto Resources/AppIcon.icon "$kit/AppIcon.icon"
cp Sources/MacClaude/Resources/FoxPilot.png "$kit/Exports/FoxPilot.png"
cp docs/images/macclaude-icon.png "$kit/Exports/AppIcon-Default.png"
cp docs/images/macclaude-banner.png "$kit/Exports/GitHub-Banner.png"
cp build/icon-preview/sizes.png "$kit/Size-Review.png"
cp docs/BRANDING.md "$kit/Asset-Guide.md"
cp design/fox-pilot/production/prompts.json "$kit/Generation-Prompts.json"
ditto -c -k --keepParent "$kit" build/MacClaude-Brand-Kit.zip
printf '%s\n' 'Exported app appearances, compatibility ICNS, and SVG/PDF/PNG menu bar marks.'
