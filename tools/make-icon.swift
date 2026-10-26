// Draws the WinSwitch app icon and writes Resources/AppIcon.icns.
// Run from the repo root: swift tools/make-icon.swift
import AppKit

func drawIcon(size: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
        let s = size / 1024
        // macOS icon grid: 824pt body centred in 1024 with a soft shadow.
        let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
        let shape = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.shadowBlurRadius = 24 * s
        shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
        shadow.set()
        NSColor.black.setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGradient(colors: [NSColor(srgbRed: 0.05, green: 0.36, blue: 0.85, alpha: 1),
                            NSColor(srgbRed: 0.10, green: 0.70, blue: 0.95, alpha: 1)])!
            .draw(in: shape, angle: 60)

        // Two overlapping windows: the back one faded, the front one solid with a title bar and a 2x2 grid.
        func window(_ rect: NSRect, alpha: CGFloat, grid: Bool) {
            let frame = NSBezierPath(roundedRect: rect, xRadius: 44 * s, yRadius: 44 * s)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.25 * alpha)
            shadow.shadowBlurRadius = 30 * s
            shadow.shadowOffset = NSSize(width: 0, height: -12 * s)
            shadow.set()
            NSColor.white.withAlphaComponent(alpha).setFill()
            frame.fill()
            NSGraphicsContext.restoreGraphicsState()

            // Title bar with three dots.
            let barHeight = 70 * s
            NSGraphicsContext.saveGraphicsState()
            frame.addClip()
            NSColor(srgbRed: 0.88, green: 0.93, blue: 1, alpha: alpha).setFill()
            NSRect(x: rect.minX, y: rect.maxY - barHeight, width: rect.width, height: barHeight).fill()
            NSGraphicsContext.restoreGraphicsState()
            for (i, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
                color.withAlphaComponent(alpha).setFill()
                let d = 22 * s
                NSBezierPath(ovalIn: NSRect(x: rect.minX + (34 + CGFloat(i) * 36) * s, y: rect.maxY - barHeight / 2 - d / 2, width: d, height: d)).fill()
            }

            guard grid else { return }
            let inset = 46 * s, gap = 22 * s
            let area = NSRect(x: rect.minX + inset, y: rect.minY + inset, width: rect.width - 2 * inset, height: rect.height - barHeight - 2 * inset)
            let w = (area.width - gap) / 2, h = (area.height - gap) / 2
            for row in 0..<2 {
                for col in 0..<2 {
                    let tile = NSRect(x: area.minX + CGFloat(col) * (w + gap), y: area.minY + CGFloat(row) * (h + gap), width: w, height: h)
                    NSColor(srgbRed: 0.05, green: 0.42, blue: 0.90, alpha: row == 1 && col == 0 ? 1 : 0.55).setFill()
                    NSBezierPath(roundedRect: tile, xRadius: 16 * s, yRadius: 16 * s).fill()
                }
            }
        }
        window(NSRect(x: 190 * s, y: 380 * s, width: 470 * s, height: 400 * s), alpha: 0.55, grid: false)
        window(NSRect(x: 350 * s, y: 230 * s, width: 490 * s, height: 420 * s), alpha: 1, grid: true)

        // Switch arrow curving from the back window to the front one.
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: 250 * s, y: 330 * s))
        arrow.curve(to: NSPoint(x: 302 * s, y: 214 * s), controlPoint1: NSPoint(x: 245 * s, y: 260 * s), controlPoint2: NSPoint(x: 270 * s, y: 218 * s))
        arrow.lineWidth = 30 * s
        arrow.lineCapStyle = .round
        NSColor.white.setStroke()
        arrow.stroke()
        let head = NSBezierPath()
        head.move(to: NSPoint(x: 355 * s, y: 212 * s))
        head.line(to: NSPoint(x: 300 * s, y: 170 * s))
        head.line(to: NSPoint(x: 300 * s, y: 258 * s))
        head.close()
        NSColor.white.setFill()
        head.fill()
        return true
    }
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        drawIcon(size: CGFloat(px)).draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try task.run()
task.waitUntilExit()
try? fm.copyItem(at: iconset.appendingPathComponent("icon_512x512@2x.png"), to: URL(fileURLWithPath: "build/AppIcon-preview.png"))
print(task.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
