#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build
binary_dir="$(swift build --show-bin-path)"
preview="$PWD/build/MacClaude Brand Preview.app"
mkdir -p "$preview/Contents/MacOS" "$preview/Contents/Resources"
cat > build/preview-resource-bundle.swift <<'SWIFT'
import Foundation
extension Bundle {
    static let module = Bundle(url: Bundle.main.resourceURL!.appendingPathComponent("MacClaude_MacClaude.bundle"))!
}
SWIFT
xcrun swiftc -module-cache-path build/module-cache Sources/MacClaude/AccountsWindow.swift \
  Sources/MacClaude/BrandArtwork.swift Sources/MacClaude/FoxMark.swift \
  build/preview-resource-bundle.swift scripts/PreviewBrand.swift \
  -o "$preview/Contents/MacOS/BrandPreview"
ditto "$binary_dir/MacClaude_MacClaude.bundle" "$preview/Contents/Resources/MacClaude_MacClaude.bundle"
cat > "$preview/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>BrandPreview</string>
<key>CFBundleIdentifier</key><string>io.github.agensdev.macclaude.brandpreview</string>
<key>CFBundleName</key><string>MacClaude Brand Preview</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$preview"
printf 'Preview ready: %s\n' "$preview"
