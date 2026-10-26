// Draws the icons of WinPad, WinCode and WinPaint and writes Resources/<App>/AppIcon.icns.
// Run from the repo root: swift tools/make-app-icons.swift
import AppKit

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

func shadowed(_ s: CGFloat, alpha: CGFloat = 0.3, blur: CGFloat = 24, y: CGFloat = -10, _ draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(alpha)
    shadow.shadowBlurRadius = blur * s
    shadow.shadowOffset = NSSize(width: 0, height: y * s)
    shadow.set()
    draw()
    NSGraphicsContext.restoreGraphicsState()
}

/// macOS icon grid: an 824pt rounded body centred in 1024, with a gradient and a soft shadow.
func body(_ s: CGFloat, _ top: NSColor, _ bottom: NSColor) -> NSBezierPath {
    let shape = NSBezierPath(roundedRect: NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s), xRadius: 185 * s, yRadius: 185 * s)
    shadowed(s) { NSColor.black.setFill(); shape.fill() }
    NSGradient(colors: [bottom, top])!.draw(in: shape, angle: 90)
    return shape
}

/// A sheet of paper with a folded corner.
func page(_ s: CGFloat, _ r: NSRect, color: NSColor = .white, fold: CGFloat = 110) -> NSBezierPath {
    let f = fold * s
    let path = NSBezierPath()
    path.move(to: NSPoint(x: r.minX, y: r.minY))
    path.line(to: NSPoint(x: r.maxX, y: r.minY))
    path.line(to: NSPoint(x: r.maxX, y: r.maxY - f))
    path.line(to: NSPoint(x: r.maxX - f, y: r.maxY))
    path.line(to: NSPoint(x: r.minX, y: r.maxY))
    path.close()
    shadowed(s, alpha: 0.25, blur: 30, y: -12) { color.setFill(); path.fill() }
    let corner = NSBezierPath()
    corner.move(to: NSPoint(x: r.maxX - f, y: r.maxY))
    corner.line(to: NSPoint(x: r.maxX - f, y: r.maxY - f))
    corner.line(to: NSPoint(x: r.maxX, y: r.maxY - f))
    corner.close()
    color.blended(withFraction: 0.18, of: .black)!.setFill()
    corner.fill()
    return path
}

func bar(_ s: CGFloat, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat = 26, _ color: NSColor) {
    color.setFill()
    NSBezierPath(roundedRect: NSRect(x: x * s, y: y * s, width: w * s, height: h * s), xRadius: h / 2 * s, yRadius: h / 2 * s).fill()
}

// WinPad: a lined notepad with a spiral binding and a pencil.
func drawPad(_ s: CGFloat) {
    _ = body(s, rgb(80, 178, 255), rgb(20, 96, 214))
    let r = NSRect(x: 250 * s, y: 190 * s, width: 500 * s, height: 620 * s)
    _ = page(s, r, fold: 0.001)
    // Header strip and spiral rings.
    rgb(255, 214, 90).setFill()
    NSRect(x: r.minX, y: r.maxY - 90 * s, width: r.width, height: 90 * s).fill()
    for i in 0..<6 {
        let x = r.minX + (52 + CGFloat(i) * 80) * s
        let ring = NSBezierPath(roundedRect: NSRect(x: x, y: r.maxY - 60 * s, width: 26 * s, height: 110 * s), xRadius: 13 * s, yRadius: 13 * s)
        ring.lineWidth = 12 * s
        rgb(90, 98, 112).setStroke()
        ring.stroke()
    }
    // Ruled lines and a margin.
    for i in 0..<8 {
        let y = r.maxY - (160 + CGFloat(i) * 58) * s
        rgb(160, 196, 240).setFill()
        NSRect(x: r.minX + 30 * s, y: y, width: r.width - 60 * s, height: 6 * s).fill()
    }
    rgb(240, 120, 120).setFill()
    NSRect(x: r.minX + 92 * s, y: r.minY + 30 * s, width: 5 * s, height: r.height - 150 * s).fill()
    // Text on the first lines.
    for (i, w) in [300, 250, 320, 180].enumerated() {
        bar(s, x: 365, y: 640 - CGFloat(i) * 58, w: CGFloat(w), h: 18, rgb(60, 70, 90))
    }
    // Pencil across the corner.
    NSGraphicsContext.saveGraphicsState()
    let t = NSAffineTransform()
    t.translateX(by: 690 * s, yBy: 300 * s)
    t.rotate(byDegrees: 40)
    t.concat()
    shadowed(s, alpha: 0.3, blur: 16, y: -6) {
        rgb(255, 170, 40).setFill()
        NSRect(x: -45 * s, y: -230 * s, width: 90 * s, height: 360 * s).fill()
    }
    rgb(240, 140, 20).setFill()
    NSRect(x: 0, y: -230 * s, width: 45 * s, height: 360 * s).fill()
    rgb(240, 110, 130).setFill()
    NSRect(x: -45 * s, y: 130 * s, width: 90 * s, height: 50 * s).fill()
    rgb(190, 196, 204).setFill()
    NSRect(x: -45 * s, y: 110 * s, width: 90 * s, height: 26 * s).fill()
    let tip = NSBezierPath()
    tip.move(to: NSPoint(x: -45 * s, y: -230 * s))
    tip.line(to: NSPoint(x: 45 * s, y: -230 * s))
    tip.line(to: NSPoint(x: 0, y: -330 * s))
    tip.close()
    rgb(245, 214, 170).setFill()
    tip.fill()
    let lead = NSBezierPath()
    lead.move(to: NSPoint(x: -15 * s, y: -297 * s))
    lead.line(to: NSPoint(x: 15 * s, y: -297 * s))
    lead.line(to: NSPoint(x: 0, y: -330 * s))
    lead.close()
    rgb(50, 50, 60).setFill()
    lead.fill()
    NSGraphicsContext.restoreGraphicsState()
}

// WinCode: a dark code sheet with highlighted lines, line numbers and a fold marker, plus a "++" badge.
func drawCode(_ s: CGFloat) {
    _ = body(s, rgb(110, 214, 120), rgb(22, 140, 72))
    let r = NSRect(x: 230 * s, y: 180 * s, width: 540 * s, height: 640 * s)
    let sheet = page(s, r, color: rgb(250, 251, 252))
    NSGraphicsContext.saveGraphicsState()
    sheet.addClip()
    rgb(228, 232, 238).setFill()
    NSRect(x: r.minX, y: r.minY, width: 96 * s, height: r.height).fill()
    NSGraphicsContext.restoreGraphicsState()
    let lines: [[(CGFloat, NSColor)]] = [
        [(120, rgb(0, 90, 220)), (150, rgb(40, 40, 50))],
        [(60, rgb(40, 40, 50)), (110, rgb(160, 30, 200)), (90, rgb(40, 40, 50))],
        [(60, rgb(40, 40, 50)), (90, rgb(0, 90, 220)), (140, rgb(200, 100, 0))],
        [(60, rgb(40, 40, 50)), (200, rgb(0, 140, 60))],
        [(60, rgb(40, 40, 50)), (90, rgb(0, 90, 220)), (100, rgb(40, 40, 50))],
        [(50, rgb(40, 40, 50))],
        [(130, rgb(0, 90, 220)), (120, rgb(40, 40, 50))],
    ]
    for (i, parts) in lines.enumerated() {
        let y = 700 - CGFloat(i) * 70
        bar(s, x: 262, y: y, w: 34, h: 18, rgb(150, 158, 170))
        var x: CGFloat = 350 + (i > 0 && i < 5 ? 40 : 0)
        for (w, color) in parts {
            bar(s, x: x, y: y, w: w, h: 22, color)
            x += w + 18
        }
    }
    // Fold box on the first line.
    let fold = NSRect(x: 306 * s, y: 696 * s, width: 30 * s, height: 30 * s)
    rgb(120, 128, 140).setStroke()
    let box = NSBezierPath(rect: fold)
    box.lineWidth = 4 * s
    box.stroke()
    rgb(120, 128, 140).setFill()
    NSRect(x: fold.minX + 7 * s, y: fold.midY - 2 * s, width: 16 * s, height: 4 * s).fill()
    // "++" badge.
    let badge = NSBezierPath(ovalIn: NSRect(x: 590 * s, y: 130 * s, width: 270 * s, height: 270 * s))
    shadowed(s, alpha: 0.35, blur: 20, y: -8) { rgb(255, 120, 40).setFill(); badge.fill() }
    for cx in [672, 778] as [CGFloat] {
        bar(s, x: cx - 40, y: 252, w: 80, h: 26, .white)
        bar(s, x: cx - 13, y: 225, w: 26, h: 80, .white)
    }
}

// WinPaint: an artist's palette with paint dabs and a brush.
func drawPaint(_ s: CGFloat) {
    _ = body(s, rgb(255, 170, 120), rgb(230, 70, 110))
    let palette = NSBezierPath()
    palette.appendOval(in: NSRect(x: 180 * s, y: 230 * s, width: 640 * s, height: 540 * s))
    let hole = NSBezierPath(ovalIn: NSRect(x: 560 * s, y: 300 * s, width: 110 * s, height: 95 * s))
    palette.append(hole.reversed)
    shadowed(s, alpha: 0.3, blur: 28, y: -12) { rgb(250, 236, 210).setFill(); palette.fill() }
    let dabs: [(CGFloat, CGFloat, NSColor)] = [
        (290, 560, rgb(230, 40, 50)), (410, 650, rgb(255, 190, 0)), (560, 650, rgb(40, 180, 80)),
        (680, 560, rgb(30, 110, 240)), (300, 400, rgb(150, 60, 200)), (430, 330, rgb(30, 30, 40)),
    ]
    for (x, y, color) in dabs {
        let dab = NSBezierPath(ovalIn: NSRect(x: (x - 55) * s, y: (y - 48) * s, width: 110 * s, height: 96 * s))
        color.setFill()
        dab.fill()
        NSColor.white.withAlphaComponent(0.35).setFill()
        NSBezierPath(ovalIn: NSRect(x: (x - 30) * s, y: (y + 5) * s, width: 34 * s, height: 22 * s)).fill()
    }
    // Brush.
    NSGraphicsContext.saveGraphicsState()
    let t = NSAffineTransform()
    t.translateX(by: 640 * s, yBy: 470 * s)
    t.rotate(byDegrees: -40)
    t.concat()
    shadowed(s, alpha: 0.3, blur: 14, y: -6) {
        rgb(120, 70, 40).setFill()
        NSBezierPath(roundedRect: NSRect(x: -22 * s, y: -40 * s, width: 44 * s, height: 420 * s), xRadius: 22 * s, yRadius: 22 * s).fill()
    }
    rgb(200, 204, 212).setFill()
    NSRect(x: -30 * s, y: -110 * s, width: 60 * s, height: 80 * s).fill()
    let tuft = NSBezierPath()
    tuft.move(to: NSPoint(x: -30 * s, y: -110 * s))
    tuft.curve(to: NSPoint(x: 0, y: -250 * s), controlPoint1: NSPoint(x: -40 * s, y: -170 * s), controlPoint2: NSPoint(x: -10 * s, y: -220 * s))
    tuft.curve(to: NSPoint(x: 30 * s, y: -110 * s), controlPoint1: NSPoint(x: 10 * s, y: -220 * s), controlPoint2: NSPoint(x: 40 * s, y: -170 * s))
    tuft.close()
    rgb(30, 110, 240).setFill()
    tuft.fill()
    NSGraphicsContext.restoreGraphicsState()
}

let fm = FileManager.default
for (app, draw) in [("WinPad", drawPad), ("WinCode", drawCode), ("WinPaint", drawPaint)] as [(String, (CGFloat) -> Void)] {
    let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(app).iconset")
    try? fm.removeItem(at: iconset)
    try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
    for base in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let px = base * scale
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            draw(CGFloat(px) / 1024)
            NSGraphicsContext.restoreGraphicsState()
            let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
            try rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
        }
    }
    try fm.createDirectory(atPath: "Resources/\(app)", withIntermediateDirectories: true)
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    task.arguments = ["-c", "icns", iconset.path, "-o", "Resources/\(app)/AppIcon.icns"]
    try task.run()
    task.waitUntilExit()
    try? fm.createDirectory(atPath: "build", withIntermediateDirectories: true)
    try? fm.removeItem(atPath: "build/\(app)-icon.png")
    try? fm.copyItem(at: iconset.appendingPathComponent("icon_512x512@2x.png"), to: URL(fileURLWithPath: "build/\(app)-icon.png"))
    print(task.terminationStatus == 0 ? "Wrote Resources/\(app)/AppIcon.icns" : "iconutil failed for \(app)")
}
