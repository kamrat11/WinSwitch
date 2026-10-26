import AppKit

/// The shapes of the Shapes gallery, in Paint's order.
enum ShapeKind: Int, CaseIterable {
    case line, curve, oval, rectangle, roundedRectangle, polygon, triangle, rightTriangle, diamond, pentagon, hexagon,
         rightArrow, leftArrow, upArrow, downArrow, star4, star5, star6, roundedCallout, ovalCallout, cloudCallout,
         heart, lightning

    var title: String {
        switch self {
        case .line: return "Line"
        case .curve: return "Curve"
        case .oval: return "Oval"
        case .rectangle: return "Rectangle"
        case .roundedRectangle: return "Rounded rectangle"
        case .polygon: return "Polygon"
        case .triangle: return "Triangle"
        case .rightTriangle: return "Right triangle"
        case .diamond: return "Diamond"
        case .pentagon: return "Pentagon"
        case .hexagon: return "Hexagon"
        case .rightArrow: return "Right arrow"
        case .leftArrow: return "Left arrow"
        case .upArrow: return "Up arrow"
        case .downArrow: return "Down arrow"
        case .star4: return "4-point star"
        case .star5: return "5-point star"
        case .star6: return "6-point star"
        case .roundedCallout: return "Rounded rectangular callout"
        case .ovalCallout: return "Oval callout"
        case .cloudCallout: return "Cloud callout"
        case .heart: return "Heart"
        case .lightning: return "Lightning"
        }
    }

    /// Shapes drawn by dragging a box (everything but line, curve and polygon).
    var isBoxed: Bool { self != .line && self != .curve && self != .polygon }
}

enum ShapePath {
    /// The outline of a boxed shape filling the rectangle (top-left coordinates).
    static func path(_ kind: ShapeKind, in r: CGRect) -> CGPath {
        let p = CGMutablePath()
        let w = r.width, h = r.height
        func pt(_ u: CGFloat, _ v: CGFloat) -> CGPoint { CGPoint(x: r.minX + u * w, y: r.minY + v * h) }
        func poly(_ points: [CGPoint]) { p.addLines(between: points); p.closeSubpath() }
        switch kind {
        case .line, .curve, .polygon, .rectangle:
            p.addRect(r)
        case .oval:
            p.addEllipse(in: r)
        case .roundedRectangle:
            let radius = min(w, h) / 6
            p.addRoundedRect(in: r, cornerWidth: radius, cornerHeight: radius)
        case .triangle:
            poly([pt(0.5, 0), pt(1, 1), pt(0, 1)])
        case .rightTriangle:
            poly([pt(0, 0), pt(1, 1), pt(0, 1)])
        case .diamond:
            poly([pt(0.5, 0), pt(1, 0.5), pt(0.5, 1), pt(0, 0.5)])
        case .pentagon:
            poly(fitted(regular(5, inner: nil), in: r))
        case .hexagon:
            poly([pt(0.25, 0), pt(0.75, 0), pt(1, 0.5), pt(0.75, 1), pt(0.25, 1), pt(0, 0.5)])
        case .star4:
            poly(fitted(regular(4, inner: 0.38), in: r))
        case .star5:
            poly(fitted(regular(5, inner: 0.38), in: r))
        case .star6:
            poly(fitted(regular(6, inner: 0.55), in: r))
        case .rightArrow, .leftArrow, .upArrow, .downArrow:
            let horizontal = kind == .rightArrow || kind == .leftArrow
            let length = horizontal ? w : h, thick = horizontal ? h : w
            let head = min(length * 0.5, thick)
            let axis: [(CGFloat, CGFloat)] = [(0, 0.25), (length - head, 0.25), (length - head, 0), (length, 0.5),
                                              (length - head, 1), (length - head, 0.75), (0, 0.75)]
            poly(axis.map { a, b in
                switch kind {
                case .rightArrow: return CGPoint(x: r.minX + a, y: r.minY + b * h)
                case .leftArrow: return CGPoint(x: r.maxX - a, y: r.minY + b * h)
                case .downArrow: return CGPoint(x: r.minX + b * w, y: r.minY + a)
                default: return CGPoint(x: r.minX + b * w, y: r.maxY - a)
                }
            })
        case .roundedCallout:
            let bottom = r.minY + h * 0.78
            let radius = min(w, bottom - r.minY) / 6
            p.move(to: CGPoint(x: r.minX + radius, y: r.minY))
            p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: bottom), radius: radius)
            p.addArc(tangent1End: CGPoint(x: r.maxX, y: bottom), tangent2End: CGPoint(x: r.minX, y: bottom), radius: radius)
            p.addLine(to: CGPoint(x: r.minX + w * 0.42, y: bottom))
            p.addLine(to: pt(0.2, 1))
            p.addLine(to: CGPoint(x: r.minX + w * 0.24, y: bottom))
            p.addArc(tangent1End: CGPoint(x: r.minX, y: bottom), tangent2End: r.origin, radius: radius)
            p.addArc(tangent1End: r.origin, tangent2End: CGPoint(x: r.maxX, y: r.minY), radius: radius)
            p.closeSubpath()
        case .ovalCallout:
            let c = CGPoint(x: r.midX, y: r.minY + h * 0.39), rx = w / 2, ry = h * 0.39
            let start = 125.0, end = 100.0 + 360
            var points: [CGPoint] = []
            var t = start
            while t <= end {
                let a = t * .pi / 180
                points.append(CGPoint(x: c.x + rx * cos(a), y: c.y + ry * sin(a)))
                t += 4
            }
            points.append(pt(0.12, 1))
            poly(points)
        case .cloudCallout:
            let c = CGPoint(x: r.midX, y: r.minY + h * 0.37), rx = w / 2, ry = h * 0.37
            var points: [CGPoint] = []
            for i in 0..<240 {
                let a = Double(i) / 240 * 2 * .pi
                let bump = 0.86 + 0.14 * abs(sin(a * 5))
                points.append(CGPoint(x: c.x + rx * bump * cos(a), y: c.y + ry * bump * sin(a)))
            }
            poly(points)
            p.addEllipse(in: CGRect(x: r.minX + w * 0.2, y: r.minY + h * 0.76, width: w * 0.1, height: h * 0.09))
            p.addEllipse(in: CGRect(x: r.minX + w * 0.1, y: r.minY + h * 0.9, width: w * 0.06, height: h * 0.07))
        case .heart:
            p.move(to: pt(0.5, 1))
            p.addCurve(to: pt(0, 0.3), control1: pt(0.15, 0.75), control2: pt(0, 0.55))
            p.addCurve(to: pt(0.27, 0), control1: pt(0, 0.1), control2: pt(0.15, 0))
            p.addCurve(to: pt(0.5, 0.22), control1: pt(0.4, 0), control2: pt(0.5, 0.1))
            p.addCurve(to: pt(0.73, 0), control1: pt(0.5, 0.1), control2: pt(0.6, 0))
            p.addCurve(to: pt(1, 0.3), control1: pt(0.85, 0), control2: pt(1, 0.1))
            p.addCurve(to: pt(0.5, 1), control1: pt(1, 0.55), control2: pt(0.85, 0.75))
            p.closeSubpath()
        case .lightning:
            poly([pt(0.35, 0), pt(0.75, 0), pt(0.55, 0.38), pt(0.82, 0.38), pt(0.22, 1), pt(0.42, 0.52), pt(0.16, 0.52)])
        }
        return p
    }

    /// Points of a regular polygon (or a star when `inner` is set) around the unit circle, top first.
    private static func regular(_ n: Int, inner: CGFloat?) -> [CGPoint] {
        let count = inner == nil ? n : n * 2
        return (0..<count).map { i in
            let a = -CGFloat.pi / 2 + CGFloat(i) * 2 * .pi / CGFloat(count)
            let radius: CGFloat = (inner != nil && i % 2 == 1) ? inner! : 1
            return CGPoint(x: cos(a) * radius, y: sin(a) * radius)
        }
    }

    private static func fitted(_ points: [CGPoint], in r: CGRect) -> [CGPoint] {
        let xs = points.map(\.x), ys = points.map(\.y)
        let minX = xs.min()!, maxX = xs.max()!, minY = ys.min()!, maxY = ys.max()!
        return points.map {
            CGPoint(x: r.minX + ($0.x - minX) / (maxX - minX) * r.width, y: r.minY + ($0.y - minY) / (maxY - minY) * r.height)
        }
    }

    /// A small line drawing of the shape for the gallery and menus.
    static func glyph(_ kind: ShapeKind, size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let r = rect.insetBy(dx: 2.5, dy: 2.5)
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setLineWidth(1.2)
            ctx.setLineJoin(.round)
            switch kind {
            case .line:
                ctx.move(to: CGPoint(x: r.minX, y: r.maxY)); ctx.addLine(to: CGPoint(x: r.maxX, y: r.minY))
            case .curve:
                ctx.move(to: CGPoint(x: r.minX, y: r.maxY))
                ctx.addCurve(to: CGPoint(x: r.maxX, y: r.minY), control1: CGPoint(x: r.minX + r.width * 0.9, y: r.maxY + 2),
                             control2: CGPoint(x: r.minX + r.width * 0.1, y: r.minY - 2))
            case .polygon:
                ctx.addLines(between: [CGPoint(x: r.minX + 3, y: r.minY), CGPoint(x: r.maxX, y: r.minY + 4),
                                       CGPoint(x: r.maxX - 3, y: r.maxY), CGPoint(x: r.minX, y: r.maxY - 3)])
                ctx.closePath()
            default:
                ctx.addPath(path(kind, in: r))
            }
            ctx.strokePath()
            return true
        }
        image.isTemplate = true
        return image
    }
}
