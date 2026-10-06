import CoreGraphics

/// A small-size companion to the illustrated mascot. Coordinates use a 24pt,
/// top-left canvas; the same paths are exported as SVG and PDF by the brand script.
enum FoxMark {
    enum Segment {
        case move(CGFloat, CGFloat), line(CGFloat, CGFloat)
        case curve(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)
        case close
    }

    // Ears, helmet/head silhouette, cheek cutout, and nose. Even-odd fill keeps
    // the face transparent so AppKit can supply the correct menu-bar tint.
    static let silhouette: [Segment] = [
        .move(4, 8), .line(3.5, 2.7),
        .curve(3.4, 1.7, 4.2, 1.3, 4.9, 2), .line(8.6, 5.2),
        .curve(10.7, 4.4, 13.3, 4.4, 15.4, 5.2), .line(19.1, 2),
        .curve(19.8, 1.3, 20.6, 1.7, 20.5, 2.7), .line(20, 8),
        .curve(21.1, 9.6, 21.5, 11.2, 21.5, 13),
        .curve(21.5, 18.1, 17.1, 22, 12, 22),
        .curve(6.9, 22, 2.5, 18.1, 2.5, 13),
        .curve(2.5, 11.2, 2.9, 9.6, 4, 8), .close,
        .move(6, 11), .curve(7.4, 9.2, 9.4, 8.5, 12, 8.5),
        .curve(14.6, 8.5, 16.6, 9.2, 18, 11),
        .line(18.6, 15), .curve(16.8, 15.2, 15.8, 16, 14.4, 18),
        .curve(13.4, 19.5, 10.6, 19.5, 9.6, 18),
        .curve(8.2, 16, 7.2, 15.2, 5.4, 15), .close,
        .move(10.2, 16.3), .curve(10.8, 15.9, 13.2, 15.9, 13.8, 16.3),
        .curve(14.1, 16.8, 12.9, 18, 12, 18.2),
        .curve(11.1, 18, 9.9, 16.8, 10.2, 16.3), .close
    ]
    static let microphone: [Segment] = [
        .move(21.4, 13.5), .curve(22.8, 18, 20.7, 20, 17, 20)
    ]

    static func path(_ segments: [Segment]) -> CGPath {
        let path = CGMutablePath()
        for segment in segments {
            switch segment {
            case let .move(x, y): path.move(to: CGPoint(x: x, y: y))
            case let .line(x, y): path.addLine(to: CGPoint(x: x, y: y))
            case let .curve(x1, y1, x2, y2, x, y):
                path.addCurve(to: CGPoint(x: x, y: y), control1: CGPoint(x: x1, y: y1), control2: CGPoint(x: x2, y: y2))
            case .close: path.closeSubpath()
            }
        }
        return path
    }

    static func draw(in context: CGContext) {
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.addPath(path(silhouette))
        context.fillPath(using: .evenOdd)
        context.fillEllipse(in: CGRect(x: 7.5, y: 11.2, width: 1.7, height: 2))
        context.fillEllipse(in: CGRect(x: 14.8, y: 11.2, width: 1.7, height: 2))
        context.setStrokeColor(CGColor(gray: 0, alpha: 1))
        context.setLineWidth(1.7)
        context.setLineCap(.round)
        context.addPath(path(microphone))
        context.strokePath()
        context.fillEllipse(in: CGRect(x: 15, y: 18.6, width: 3.4, height: 2.6))
    }
}
