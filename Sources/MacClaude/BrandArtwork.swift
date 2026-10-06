import AppKit

@MainActor
enum BrandArtwork {
    static let pilot: NSImage? = Bundle.module.url(forResource: "FoxPilot", withExtension: "png")
        .flatMap { NSImage(contentsOf: $0) }

    static let menuBarIcon: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
            NSGraphicsContext.saveGraphicsState()
            let context = NSGraphicsContext.current!.cgContext
            context.scaleBy(x: rect.width / 24, y: rect.height / 24)
            FoxMark.draw(in: context)
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "MacClaude accounts"
        return image
    }()
}
