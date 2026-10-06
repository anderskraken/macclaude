import AppKit

/// Mechanical exports of the approved artwork; no network or generative step.
@main
struct BrandExport {
    static func bitmap(width: Int, height: Int, draw: (CGContext) -> Void) -> NSBitmapImageRep {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let context = NSGraphicsContext.current!.cgContext
        context.interpolationQuality = .high
        draw(context)
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }

    static func save(_ bitmap: NSBitmapImageRep, to path: String) throws {
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    }

    static func svgPath(_ segments: [FoxMark.Segment]) -> String {
        segments.map { segment in
            switch segment {
            case let .move(x, y): return "M\(x) \(y)"
            case let .line(x, y): return "L\(x) \(y)"
            case let .curve(x1, y1, x2, y2, x, y): return "C\(x1) \(y1) \(x2) \(y2) \(x) \(y)"
            case .close: return "Z"
            }
        }.joined(separator: " ")
    }

    static func main() throws {
        let root = CommandLine.arguments[1]
        let brand = "\(root)/Resources/Brand"
        let preview = "\(root)/build/icon-preview"
        let iconset = "\(preview)/AppIcon.iconset"
        try FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
        let icon = NSImage(contentsOfFile: "\(root)/docs/images/macclaude-icon.png")!
        // Legacy ICNS needs its own transparent margin. The .icon canvas remains
        // full bleed, letting modern macOS supply its own mask and footprint.
        for (points, scale) in [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),(256,1),(256,2),(512,1),(512,2)] {
            let pixels = points * scale
            let result = bitmap(width: pixels, height: pixels) { context in
                context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
                let shadow = NSShadow()
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.2)
                shadow.shadowBlurRadius = 18
                shadow.shadowOffset = NSSize(width: 0, height: -7)
                shadow.set()
                icon.draw(in: NSRect(x: 100, y: 100, width: 824, height: 824))
            }
            try save(result, to: "\(iconset)/icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png")
        }

        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="currentColor">
          <title>MacClaude fox pilot</title>
          <path fill-rule="evenodd" d="\(svgPath(FoxMark.silhouette))"/>
          <ellipse cx="8.35" cy="12.2" rx="0.85" ry="1"/>
          <ellipse cx="15.65" cy="12.2" rx="0.85" ry="1"/>
          <path d="\(svgPath(FoxMark.microphone))" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round"/>
          <ellipse cx="16.7" cy="19.9" rx="1.7" ry="1.3"/>
        </svg>
        """
        try svg.write(toFile: "\(brand)/FoxPilot-Mark.svg", atomically: true, encoding: .utf8)
        for size in [18, 36, 72, 256] {
            try save(bitmap(width: size, height: size) { context in
                context.translateBy(x: 0, y: CGFloat(size))
                context.scaleBy(x: CGFloat(size) / 24, y: -CGFloat(size) / 24)
                FoxMark.draw(in: context)
            }, to: "\(brand)/FoxPilot-Mark-\(size).png")
        }
        var mediaBox = CGRect(x: 0, y: 0, width: 24, height: 24)
        let pdf = CGContext(URL(fileURLWithPath: "\(brand)/FoxPilot-Mark.pdf") as CFURL, mediaBox: &mediaBox, nil)!
        pdf.beginPDFPage(nil)
        pdf.translateBy(x: 0, y: 24)
        pdf.scaleBy(x: 1, y: -1)
        FoxMark.draw(in: pdf)
        pdf.endPDFPage()
        pdf.closePDF()

        // Size/contrast review sheet, showing the exact generated template mark.
        try save(bitmap(width: 1000, height: 420) { context in
            NSColor(srgbRed: 0.97, green: 0.95, blue: 0.92, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: 1000, height: 420).fill()
            NSColor(srgbRed: 0.13, green: 0.12, blue: 0.11, alpha: 1).setFill()
            NSRect(x: 500, y: 0, width: 500, height: 420).fill()
            for origin in [0, 500] {
                let ink: NSColor = origin == 0 ? .black : .white
                ("App icon / 128 · 64 · 32 · 16" as NSString).draw(at: NSPoint(x: origin + 28, y: 370),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 16, weight: .medium), .foregroundColor: ink])
                var x = CGFloat(origin + 28)
                for size in [128, 64, 32, 16] {
                    icon.draw(in: NSRect(x: x, y: 200, width: CGFloat(size), height: CGFloat(size)))
                    x += CGFloat(size + 26)
                }
                ("Menu bar mark / 18 · 18 @2x · 36" as NSString).draw(at: NSPoint(x: origin + 28, y: 125),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 16, weight: .medium), .foregroundColor: ink])
                x = CGFloat(origin + 28)
                for size in [18, 36, 72] {
                    context.saveGState()
                    context.translateBy(x: x, y: 45 + CGFloat(size))
                    context.scaleBy(x: CGFloat(size) / 24, y: -CGFloat(size) / 24)
                    if origin == 0 {
                        FoxMark.draw(in: context)
                    } else {
                        context.beginTransparencyLayer(auxiliaryInfo: nil)
                        FoxMark.draw(in: context)
                        context.setBlendMode(.sourceIn)
                        context.setFillColor(NSColor.white.cgColor)
                        context.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
                        context.endTransparencyLayer()
                    }
                    context.restoreGState()
                    x += CGFloat(size + 42)
                }
            }
        }, to: "\(preview)/sizes.png")
    }
}
