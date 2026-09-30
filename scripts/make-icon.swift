import AppKit

// Resolution-independent artwork: no downloaded assets, fonts, or runtime dependencies.
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}
func rounded(_ rect: NSRect, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}
func gradient(_ path: NSBezierPath, _ top: UInt32, _ bottom: UInt32) {
    NSGradient(starting: color(bottom), ending: color(top))!.draw(in: path, angle: 90)
}
func outline(_ path: NSBezierPath, _ ink: NSColor, _ width: CGFloat) {
    ink.setStroke(); path.lineWidth = width; path.stroke()
}
func shadow(_ blur: CGFloat, _ y: CGFloat, _ alpha: CGFloat, draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(0x38180F, alpha)
    shadow.shadowBlurRadius = blur
    shadow.shadowOffset = NSSize(width: 0, height: y)
    shadow.set(); draw()
    NSGraphicsContext.restoreGraphicsState()
}
func rotated(_ degrees: CGFloat, center: CGPoint, draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let cg = NSGraphicsContext.current!.cgContext
    cg.translateBy(x: center.x, y: center.y)
    cg.rotate(by: degrees * .pi / 180)
    cg.translateBy(x: -center.x, y: -center.y)
    draw(); NSGraphicsContext.restoreGraphicsState()
}
func person(x: CGFloat, y: CGFloat, ink: NSColor, scale: CGFloat = 1) {
    ink.setFill()
    NSBezierPath(ovalIn: NSRect(x: x + 35 * scale, y: y + 79 * scale,
                              width: 76 * scale, height: 76 * scale)).fill()
    let body = NSBezierPath()
    body.move(to: CGPoint(x: x, y: y + 14 * scale))
    body.curve(to: CGPoint(x: x + 146 * scale, y: y + 14 * scale),
               controlPoint1: CGPoint(x: x, y: y + 94 * scale),
               controlPoint2: CGPoint(x: x + 146 * scale, y: y + 94 * scale))
    body.curve(to: CGPoint(x: x + 132 * scale, y: y),
               controlPoint1: CGPoint(x: x + 146 * scale, y: y),
               controlPoint2: CGPoint(x: x + 141 * scale, y: y))
    body.line(to: CGPoint(x: x + 14 * scale, y: y))
    body.curve(to: CGPoint(x: x, y: y + 14 * scale),
               controlPoint1: CGPoint(x: x + 5 * scale, y: y),
               controlPoint2: CGPoint(x: x, y: y))
    body.close(); body.fill()
}
func arrow(from: CGPoint, to: CGPoint, direction: CGFloat) {
    let p = NSBezierPath()
    p.move(to: from); p.line(to: to)
    p.move(to: CGPoint(x: to.x - direction * 30, y: to.y + 30))
    p.line(to: to)
    p.line(to: CGPoint(x: to.x - direction * 30, y: to.y - 30))
    p.lineWidth = 25; p.lineCapStyle = .round; p.lineJoinStyle = .round
    color(0xA6533D).setStroke(); p.stroke()
}
for (points, scale) in [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),(256,1),(256,2),(512,1),(512,2)] {
    let pixels = points * scale
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                 isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)!
    let cg = NSGraphicsContext.current!.cgContext
    cg.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    cg.setShouldAntialias(true)

    // Standard macOS tile footprint, with a softly rounded edge and cast shadow.
    let tile = rounded(NSRect(x: 100, y: 100, width: 824, height: 824), 185)
    shadow(32, -13, 0.29) { color(0x9A4936).setFill(); tile.fill() }
    gradient(tile, 0xE4A17E, 0xAA513D)
    NSGraphicsContext.saveGraphicsState()
    tile.addClip()
    let glow = tile
    NSGradient(starting: color(0xFFE8C7, 0.36), ending: color(0xFFE8C7, 0))!
        .draw(in: glow, relativeCenterPosition: NSPoint(x: -0.25, y: 0.3))
    NSGraphicsContext.restoreGraphicsState()
    outline(rounded(NSRect(x: 103, y: 103, width: 818, height: 818), 182), color(0x723322, 0.25), 3)
    outline(rounded(NSRect(x: 108, y: 108, width: 808, height: 808), 178), color(0xFFE5CD, 0.30), 3)

    // Two physical account cards. Their offset remains legible at Dock sizes.
    rotated(10, center: CGPoint(x: 554, y: 615)) {
        let back = rounded(NSRect(x: 318, y: 454, width: 474, height: 340), 57)
        shadow(28, -16, 0.24) { color(0xECC5A8).setFill(); back.fill() }
        gradient(back, 0xFAE1C8, 0xDDB394)
        outline(rounded(NSRect(x: 322, y: 458, width: 466, height: 332), 53), color(0xFFF7E6, 0.72), 3)
        person(x: 370, y: 598, ink: color(0xB77559, 0.62), scale: 0.72)
        color(0xB77559, 0.38).setFill()
        rounded(NSRect(x: 520, y: 695, width: 172, height: 18), 9).fill()
        rounded(NSRect(x: 520, y: 655, width: 113, height: 18), 9).fill()
    }
    rotated(-7, center: CGPoint(x: 467, y: 435)) {
        let front = rounded(NSRect(x: 211, y: 252, width: 522, height: 374), 62)
        // Small lower lip gives the face the thickness of a real card.
        shadow(34, -20, 0.32) { color(0xC9A98E).setFill();
            rounded(NSRect(x: 211, y: 242, width: 522, height: 374), 62).fill() }
        gradient(front, 0xFFFBF0, 0xEEE1CE)
        outline(rounded(NSRect(x: 215, y: 256, width: 514, height: 366), 58), color(0xFFFFFF, 0.82), 3)
        // Slightly recessed glyphs, deliberately broad enough for 16px rendering.
        person(x: 266, y: 354, ink: color(0xB86E50))
        arrow(from: CGPoint(x: 487, y: 479), to: CGPoint(x: 641, y: 479), direction: 1)
        arrow(from: CGPoint(x: 641, y: 388), to: CGPoint(x: 487, y: 388), direction: -1)
    }
    NSGraphicsContext.restoreGraphicsState()
    let filename = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(filename))
}
