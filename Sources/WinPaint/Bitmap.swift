import AppKit

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

extension NSColor {
    /// The color as premultiplied RGBA bytes packed the way the bitmap stores them (R first in memory).
    var pixelValue: UInt32 {
        let c = usingColorSpace(.sRGB) ?? .black
        let a = max(0, min(1, c.alphaComponent))
        func byte(_ v: CGFloat) -> UInt32 { UInt32((max(0, min(1, v)) * a * 255).rounded()) }
        return byte(c.redComponent) | byte(c.greenComponent) << 8 | byte(c.blueComponent) << 16
            | UInt32((a * 255).rounded()) << 24
    }

    convenience init(pixel: UInt32) {
        let a = CGFloat(pixel >> 24 & 0xFF) / 255
        func un(_ shift: UInt32) -> CGFloat { a == 0 ? 0 : min(1, CGFloat(pixel >> shift & 0xFF) / 255 / a) }
        self.init(srgbRed: un(0), green: un(8), blue: un(16), alpha: a)
    }
}

/// An RGBA image in memory with a top-left origin, the canvas of the document.
@MainActor
final class Bitmap {
    let width: Int
    let height: Int
    let context: CGContext

    var size: CGSize { CGSize(width: width, height: height) }
    var bounds: CGRect { CGRect(origin: .zero, size: size) }

    init(width: Int, height: Int, fill: NSColor? = .white) {
        self.width = max(1, width)
        self.height = max(1, height)
        context = CGContext(data: nil, width: self.width, height: self.height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                | CGBitmapInfo.byteOrder32Big.rawValue)!
        context.translateBy(x: 0, y: CGFloat(self.height))
        context.scaleBy(x: 1, y: -1)
        if let fill {
            context.setFillColor(fill.cgColor)
            context.fill(bounds)
        }
    }

    convenience init(image: CGImage) {
        self.init(width: image.width, height: image.height, fill: nil)
        context.interpolationQuality = .none
        draw(image, in: bounds)
    }

    func makeImage() -> CGImage { context.makeImage()! }

    /// Draws an image upright in top-left coordinates.
    func draw(_ image: CGImage, in rect: CGRect, interpolation: CGInterpolationQuality = .none, alpha: CGFloat = 1) {
        context.saveGState()
        context.interpolationQuality = interpolation
        context.setAlpha(alpha)
        context.drawFlipped(image, in: rect)
        context.restoreGState()
    }

    private var stride: Int { context.bytesPerRow / 4 }
    private var pixels: UnsafeMutablePointer<UInt32> { context.data!.bindMemory(to: UInt32.self, capacity: stride * height) }

    func contains(_ x: Int, _ y: Int) -> Bool { x >= 0 && y >= 0 && x < width && y < height }

    func pixel(_ x: Int, _ y: Int) -> UInt32 { contains(x, y) ? pixels[y * stride + x] : 0 }

    func setPixel(_ x: Int, _ y: Int, _ value: UInt32) {
        if contains(x, y) { pixels[y * stride + x] = value }
    }

    func clear() {
        context.clear(CGRect(x: -1, y: -1, width: width + 2, height: height + 2))
    }

    /// Scanline flood fill of the 4-connected area that has exactly the color of the start pixel.
    func floodFill(x: Int, y: Int, with value: UInt32) {
        guard contains(x, y) else { return }
        let p = pixels, w = width, h = height, s = stride
        let target = p[y * s + x]
        guard target != value else { return }
        var stack = [(x, y)]
        while let (sx, sy) = stack.popLast() {
            var lx = sx
            while lx > 0 && p[sy * s + lx - 1] == target { lx -= 1 }
            var rx = sx
            while rx < w - 1 && p[sy * s + rx + 1] == target { rx += 1 }
            guard p[sy * s + sx] == target else { continue }
            for xx in lx...rx { p[sy * s + xx] = value }
            for ny in [sy - 1, sy + 1] where ny >= 0 && ny < h {
                var xx = lx
                while xx <= rx {
                    if p[ny * s + xx] == target {
                        stack.append((xx, ny))
                        while xx <= rx && p[ny * s + xx] == target { xx += 1 }
                    } else {
                        xx += 1
                    }
                }
            }
        }
    }

    /// Makes every pixel of one color transparent (the transparent selection option).
    func makeTransparent(_ value: UInt32) {
        let p = pixels
        for y in 0..<height { for x in 0..<width where p[y * stride + x] == value { p[y * stride + x] = 0 } }
    }

    func invertColors() {
        let p = pixels
        for y in 0..<height {
            for x in 0..<width {
                let v = p[y * stride + x], a = v >> 24 & 0xFF
                let r = a - min(a, v & 0xFF), g = a - min(a, v >> 8 & 0xFF), b = a - min(a, v >> 16 & 0xFF)
                p[y * stride + x] = r | g << 8 | b << 16 | a << 24
            }
        }
    }

    func copy() -> Bitmap { Bitmap(image: makeImage()) }

    func cropped(to rect: CGRect) -> Bitmap {
        let r = rect.integral
        let out = Bitmap(width: Int(r.width), height: Int(r.height), fill: nil)
        out.draw(makeImage(), in: CGRect(x: -r.minX, y: -r.minY, width: CGFloat(width), height: CGFloat(height)))
        return out
    }

    /// A new bitmap of the given size with this image drawn through a top-left based transform.
    func transformed(width w: Int, height h: Int, _ t: CGAffineTransform, fill: NSColor? = nil,
                     interpolation: CGInterpolationQuality = .none) -> Bitmap {
        let out = Bitmap(width: w, height: h, fill: fill)
        out.context.saveGState()
        out.context.concatenate(t)
        out.draw(makeImage(), in: bounds, interpolation: interpolation)
        out.context.restoreGState()
        return out
    }

    enum Turn { case right, left, half, flipHorizontal, flipVertical }

    func turned(_ turn: Turn) -> Bitmap {
        let w = CGFloat(width), h = CGFloat(height)
        switch turn {
        case .right: return transformed(width: height, height: width, CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0))
        case .left: return transformed(width: height, height: width, CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w))
        case .half: return transformed(width: width, height: height, CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h))
        case .flipHorizontal: return transformed(width: width, height: height, CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0))
        case .flipVertical: return transformed(width: width, height: height, CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h))
        }
    }

    func resized(width w: Int, height h: Int) -> Bitmap {
        let t = CGAffineTransform(scaleX: CGFloat(max(1, w)) / CGFloat(width), y: CGFloat(max(1, h)) / CGFloat(height))
        return transformed(width: w, height: h, t, interpolation: .high)
    }

    /// Skews by the given angles in degrees; the uncovered corners take the fill color.
    func skewed(horizontal: Double, vertical: Double, fill: NSColor?) -> Bitmap {
        let tx = CGFloat(tan(horizontal * .pi / 180)), ty = CGFloat(tan(vertical * .pi / 180))
        let w = CGFloat(width), h = CGFloat(height)
        let nw = Int((w + abs(tx) * h).rounded()), nh = Int((h + abs(ty) * w).rounded())
        let t = CGAffineTransform(a: 1, b: ty, c: tx, d: 1, tx: tx < 0 ? -tx * h : 0, ty: ty < 0 ? -ty * w : 0)
        return transformed(width: nw, height: nh, t, fill: fill, interpolation: .high)
    }
}

extension CGContext {
    /// Draws an image upright in a context whose y axis points down.
    func drawFlipped(_ image: CGImage, in rect: CGRect) {
        saveGState()
        translateBy(x: 0, y: rect.maxY)
        scaleBy(x: 1, y: -1)
        draw(image, in: CGRect(x: rect.minX, y: 0, width: rect.width, height: rect.height))
        restoreGState()
    }
}
