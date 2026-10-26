import AppKit

enum BrushKind: Int, CaseIterable {
    case brush, calligraphyBrush, calligraphyPen, airbrush, oilBrush, crayon, marker, naturalPencil, watercolor

    var title: String {
        switch self {
        case .brush: return "Brush"
        case .calligraphyBrush: return "Calligraphy brush"
        case .calligraphyPen: return "Calligraphy pen"
        case .airbrush: return "Airbrush"
        case .oilBrush: return "Oil brush"
        case .crayon: return "Crayon"
        case .marker: return "Marker"
        case .naturalPencil: return "Natural pencil"
        case .watercolor: return "Watercolor brush"
        }
    }

    var symbol: String {
        switch self {
        case .brush, .oilBrush, .watercolor: return "paintbrush"
        case .calligraphyBrush, .calligraphyPen: return "paintbrush.pointed"
        case .airbrush: return "aqi.medium"
        case .crayon, .naturalPencil: return "pencil.tip"
        case .marker: return "highlighter"
        }
    }

    /// Brushes painted on a layer that is composited once with this opacity, so a stroke does not build up on itself.
    var layerAlpha: CGFloat? {
        switch self {
        case .marker: return 0.55
        case .watercolor: return 0.35
        default: return nil
        }
    }
}

/// What a freehand stroke paints with.
enum StrokeKind: Equatable {
    case pencil, eraser, brush(BrushKind)
}

/// Paints one freehand stroke into a bitmap, one segment at a time.
@MainActor
final class StrokeEngine {
    let kind: StrokeKind
    let target: Bitmap
    let color: NSColor
    let size: CGFloat
    private(set) var last: CGPoint
    private var bristles: [(CGPoint, CGFloat, CGFloat)] = []

    init(kind: StrokeKind, target: Bitmap, color: NSColor, size: CGFloat, start: CGPoint) {
        self.kind = kind
        self.target = target
        self.color = color
        self.size = size
        last = start
        if case .brush(.oilBrush) = kind {
            let radius = size * 1.2 + 1
            for _ in 0..<max(5, Int(size * 1.6)) {
                let a = CGFloat.random(in: 0..<(2 * .pi)), d = CGFloat.random(in: 0...radius)
                bristles.append((CGPoint(x: cos(a) * d, y: sin(a) * d), .random(in: 0.35...1), .random(in: 1...2.2)))
            }
        }
        segment(from: start, to: start)
    }

    var ctx: CGContext { target.context }

    func extend(to p: CGPoint) {
        segment(from: last, to: p)
        last = p
    }

    /// Called repeatedly while the button is held still (the airbrush keeps spraying).
    func tick() {
        if case .brush(.airbrush) = kind { spray(at: last) }
    }

    private func segment(from a: CGPoint, to b: CGPoint) {
        switch kind {
        case .pencil:
            stampLine(from: a, to: b, side: Int(max(1, size)), color: color)
        case .eraser:
            stampLine(from: a, to: b, side: Int(size * 2 + 2), color: color)
        case .brush(let brush):
            paint(brush, from: a, to: b)
        }
    }

    /// Aliased square stamps along a Bresenham line, exact to the pixel like Paint's pencil and eraser.
    private func stampLine(from a: CGPoint, to b: CGPoint, side: Int, color: NSColor) {
        ctx.saveGState()
        ctx.setShouldAntialias(false)
        ctx.setFillColor(color.cgColor)
        ctx.setBlendMode(.copy)
        var x0 = Int(floor(a.x)), y0 = Int(floor(a.y))
        let x1 = Int(floor(b.x)), y1 = Int(floor(b.y))
        let dx = abs(x1 - x0), dy = -abs(y1 - y0), sx = x0 < x1 ? 1 : -1, sy = y0 < y1 ? 1 : -1
        var err = dx + dy
        let half = side / 2
        while true {
            ctx.fill(CGRect(x: x0 - half, y: y0 - half, width: side, height: side))
            if x0 == x1 && y0 == y1 { break }
            let e2 = 2 * err
            if e2 >= dy { err += dy; x0 += sx }
            if e2 <= dx { err += dx; y0 += sy }
        }
        ctx.restoreGState()
    }

    private func strokeSegment(_ a: CGPoint, _ b: CGPoint, width: CGFloat, color: NSColor, cap: CGLineCap = .round) {
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(width)
        ctx.setLineCap(cap)
        ctx.setLineJoin(.round)
        ctx.move(to: a)
        ctx.addLine(to: b)
        ctx.strokePath()
    }

    /// Points every `step` pixels from a to b, b included.
    private func steps(from a: CGPoint, to b: CGPoint, step: CGFloat) -> [CGPoint] {
        let d = hypot(b.x - a.x, b.y - a.y)
        let n = max(1, Int(d / max(step, 0.5)))
        return (1...n).map { i in
            let t = CGFloat(i) / CGFloat(n)
            return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        }
    }

    private func paint(_ brush: BrushKind, from a: CGPoint, to b: CGPoint) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        switch brush {
        case .brush:
            strokeSegment(a, b, width: size + 1, color: color)
        case .calligraphyBrush, .calligraphyPen:
            let angle: CGFloat = brush == .calligraphyBrush ? .pi / 4 : 3 * .pi / 4
            let half = (brush == .calligraphyBrush ? size * 2 + 3 : size * 1.2 + 2) / 2
            let n = CGPoint(x: cos(angle) * half, y: -sin(angle) * half)
            ctx.setFillColor(color.cgColor)
            ctx.addLines(between: [CGPoint(x: a.x + n.x, y: a.y + n.y), CGPoint(x: a.x - n.x, y: a.y - n.y),
                                   CGPoint(x: b.x - n.x, y: b.y - n.y), CGPoint(x: b.x + n.x, y: b.y + n.y)])
            ctx.closePath()
            ctx.fillPath()
            strokeSegment(CGPoint(x: b.x + n.x, y: b.y + n.y), CGPoint(x: b.x - n.x, y: b.y - n.y), width: 1.2, color: color)
        case .airbrush:
            for p in steps(from: a, to: b, step: size + 2) { spray(at: p) }
        case .oilBrush:
            for (offset, alpha, width) in bristles {
                strokeSegment(CGPoint(x: a.x + offset.x, y: a.y + offset.y), CGPoint(x: b.x + offset.x, y: b.y + offset.y),
                              width: width, color: color.withAlphaComponent(alpha))
            }
        case .crayon:
            let radius = size * 1.3 + 1.5
            ctx.setShouldAntialias(false)
            ctx.setFillColor(color.withAlphaComponent(0.75).cgColor)
            for p in steps(from: a, to: b, step: max(1, radius / 2)) {
                for _ in 0..<Int(radius * radius * 0.9 + 2) {
                    let dx = CGFloat.random(in: -radius...radius), dy = CGFloat.random(in: -radius...radius)
                    if dx * dx + dy * dy <= radius * radius {
                        ctx.fill(CGRect(x: floor(p.x + dx), y: floor(p.y + dy), width: 1, height: 1))
                    }
                }
            }
        case .marker:
            strokeSegment(a, b, width: size * 3 + 4, color: color, cap: .square)
        case .naturalPencil:
            strokeSegment(a, b, width: max(1, size * 0.6), color: color.withAlphaComponent(0.55))
            ctx.setFillColor(color.withAlphaComponent(0.4).cgColor)
            for p in steps(from: a, to: b, step: 2) {
                let dx = CGFloat.random(in: -size...size) * 0.6, dy = CGFloat.random(in: -size...size) * 0.6
                ctx.fill(CGRect(x: p.x + dx, y: p.y + dy, width: 1, height: 1))
            }
        case .watercolor:
            ctx.setShadow(offset: .zero, blur: size + 2, color: color.cgColor)
            strokeSegment(a, b, width: size * 3 + 6, color: color)
        }
    }

    private func spray(at p: CGPoint) {
        let radius = size * 3 + 5
        ctx.saveGState()
        ctx.setShouldAntialias(false)
        ctx.setFillColor(color.cgColor)
        for _ in 0..<Int(radius * 0.9 + 4) {
            let a = CGFloat.random(in: 0..<(2 * .pi)), d = sqrt(CGFloat.random(in: 0...1)) * radius
            ctx.fill(CGRect(x: floor(p.x + cos(a) * d), y: floor(p.y + sin(a) * d), width: 1, height: 1))
        }
        ctx.restoreGState()
    }
}
