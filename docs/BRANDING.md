# Fox pilot identity

MacClaude’s Co-pilot is a friendly terracotta fox with an ivory flight helmet, raised charcoal visor, and a small communications microphone. Keep those features consistent across illustrations. The full-color character is for the app icon and larger artwork; the small monochrome mark is for the menu bar.

## Assets

| Use | Source / export |
| --- | --- |
| Native layered app icon | `Resources/AppIcon.icon` — editable in Apple Icon Composer |
| Compatibility icon | `Resources/Brand/AppIcon.icns` — all standard 16–1024px representations |
| Default icon PNG | `docs/images/macclaude-icon.png` — 1024px, system-rendered |
| Dark / tinted previews | `Resources/Brand/AppIcon-Dark.png`, `AppIcon-Tinted.png` |
| Main-screen mascot | `Sources/MacClaude/Resources/FoxPilot.png` — transparent bust |
| Larger mascot | `Resources/Brand/FoxPilot-Wave.png` — transparent full-body illustration |
| Menu bar / monochrome mark | `Resources/Brand/FoxPilot-Mark.svg`, `.pdf`, and PNGs at 18, 36, 72, 256px |
| GitHub README banner | `docs/images/macclaude-banner.png` — 1942 × 809px |

The head illustration is bundled by SwiftPM and appears beside the Accounts heading. The menu bar draws the vector paths in `Sources/MacClaude/FoxMark.swift` at 18pt as an AppKit template image, so macOS chooses the tint for light, dark, and selected states. The exported SVG and PDF use the same geometry. Do not downscale the detailed app icon to make a menu bar symbol.

## Apple icon treatment

Reviewed against Apple’s [app icon guidance](https://developer.apple.com/design/human-interface-guidelines/app-icons/) and [Icon Composer workflow](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer) on 2026-10-03.

The source document separates the background fill from the transparent character. It has no baked rounded-square mask; Apple’s renderer supplies the shape, background lighting, and appearance variants. Foreground glass distortion is disabled to preserve the illustrated face. The raster foreground is intentional for the selected sculpted style. Do not replace the document with a pre-rounded flattened image.

Xcode 26+ compiles the document into `Assets.car` and registers `CFBundleIconName`. Earlier Xcodes use the committed compatibility ICNS. That ICNS has its own transparent macOS margins and every standard size. The modern document stays full bleed. The default, dark, and tinted PNGs are previews; the compiled asset catalog supplies system-selected appearances at runtime.

## Rebuilding and reviewing

Run `make brand` with Xcode 26+ to export the icon appearances, full ICNS, menu mark formats, size/contrast review sheet, and a reusable `build/MacClaude-Brand-Kit.zip`. The script copies the canonical bust into the Icon Composer document before exporting. Regenerate after changing the character or document settings.

Run `make build` to package the artwork into `build/MacClaude.app`. Local builds are ad-hoc signed unless a signing identity is provided. This does not publish a release or notarize the app.

Run `bash scripts/preview-brand.sh`, then open `build/MacClaude Brand Preview.app`, to inspect the real Accounts UI in light and dark appearances at normal and minimum window sizes. The preview uses synthetic accounts and never accesses Claude or MacClaude’s account storage. Its controls do not perform account actions.

The images were created using built-in image generation. The chosen initial study is `design/fox-pilot/01-copilot.png`; production prompts and reference information are in `design/fox-pilot/production/prompts.json`. Image regeneration is a separate creative step from the deterministic `make brand` exports.
