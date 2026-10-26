import AppKit

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, image: NSImage? = nil, checked: Bool = false, key: String = "", handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
        self.image = image
        state = checked ? .on : .off
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}

func symbol(_ name: String, size: CGFloat = 15, weight: NSFont.Weight = .regular) -> NSImage? {
    NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: size, weight: weight))
}

/// A flat toolbar button like the ones in Paint's ribbon: an icon (and optional title) that highlights on hover and
/// when selected. With a menu it shows a chevron; `splitMenu` opens the menu only from the chevron part.
final class RibbonButton: NSView {
    enum Style { case small, large, text, gallery }

    var image: NSImage? { didSet { needsDisplay = true } }
    var title: String? { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var isSelected = false { didSet { needsDisplay = true } }
    var isEnabled = true { didSet { needsDisplay = true } }
    var action: (() -> Void)?
    var menuProvider: (() -> NSMenu)? { didSet { invalidateIntrinsicContentSize() } }
    var splitMenu = false
    /// Draws the image as is instead of tinting it with the text color.
    var keepsImageColors = false
    let style: Style
    private var hovering = false { didSet { needsDisplay = true } }
    private var pressed = false { didSet { needsDisplay = true } }

    init(style: Style, image: NSImage?, title: String? = nil, toolTip: String?) {
        self.style = style
        self.image = image
        self.title = title
        super.init(frame: .zero)
        self.toolTip = toolTip
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        switch style {
        case .small: return NSSize(width: menuProvider != nil ? 38 : 28, height: 26)
        case .gallery: return NSSize(width: 21, height: 21)
        case .large: return NSSize(width: 46, height: 60)
        case .text:
            let width = ((title ?? "") as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width
            return NSSize(width: ceil(width) + (image != nil ? 24 : 0) + (menuProvider != nil ? 30 : 16), height: 24)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        let p = convert(event.locationInWindow, from: nil)
        if let menuProvider, !splitMenu || inChevron(p) {
            pressed = true
            let menu = menuProvider()
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 2), in: self)
            pressed = false
            hovering = false
            return
        }
        pressed = true
        while let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            let inside = bounds.contains(convert(next.locationInWindow, from: nil))
            if next.type == .leftMouseUp {
                pressed = false
                if inside { action?() }
                break
            }
            pressed = inside
        }
    }

    private func inChevron(_ p: NSPoint) -> Bool {
        switch style {
        case .large: return p.y > bounds.height - 18
        default: return p.x > bounds.width - 14
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4)
        if isSelected {
            NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
            path.fill()
            NSColor.controlAccentColor.withAlphaComponent(0.55).setStroke()
            path.lineWidth = 1
            path.stroke()
        } else if pressed {
            NSColor.labelColor.withAlphaComponent(0.14).setFill()
            path.fill()
        } else if hovering && isEnabled {
            NSColor.labelColor.withAlphaComponent(0.07).setFill()
            path.fill()
        }
        let color = isEnabled ? NSColor.labelColor : NSColor.tertiaryLabelColor
        let hasChevron = menuProvider != nil

        var imageArea = bounds
        switch style {
        case .large: imageArea = NSRect(x: 0, y: 4, width: bounds.width, height: bounds.height - 22)
        case .small: if hasChevron { imageArea.size.width -= 12 }
        case .text: imageArea = NSRect(x: 4, y: 0, width: image == nil ? 0 : 20, height: bounds.height)
        case .gallery: break
        }
        if let image {
            let s = image.size
            let r = NSRect(x: (imageArea.midX - s.width / 2).rounded(), y: (imageArea.midY - s.height / 2).rounded(),
                           width: s.width, height: s.height)
            if keepsImageColors { image.draw(in: r) } else { tinted(image, color).draw(in: r) }
        }
        if style == .text, let title {
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: color]
            let size = (title as NSString).size(withAttributes: attrs)
            (title as NSString).draw(at: NSPoint(x: imageArea.maxX + 6, y: (bounds.height - size.height) / 2), withAttributes: attrs)
        }
        if hasChevron, let chevron = symbol("chevron.down", size: 8, weight: .semibold) {
            let c = tinted(chevron, NSColor.secondaryLabelColor)
            let r: NSRect
            switch style {
            case .large: r = NSRect(x: (bounds.midX - c.size.width / 2).rounded(), y: bounds.height - 14, width: c.size.width, height: c.size.height)
            default: r = NSRect(x: bounds.width - 13, y: (bounds.midY - c.size.height / 2).rounded(), width: c.size.width, height: c.size.height)
            }
            c.draw(in: r)
        }
    }
}

func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
    NSImage(size: image.size, flipped: false) { rect in
        image.draw(in: rect)
        color.set()
        rect.fill(using: .sourceAtop)
        return true
    }
}

/// One color of the palette; left click picks it for the active color, right click for Color 2.
final class SwatchView: NSView {
    var color: NSColor? { didSet { needsDisplay = true; toolTip = color.map(colorName) } }
    var onPick: ((NSColor, Bool) -> Void)?

    init(color: NSColor?) {
        self.color = color
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 18).isActive = true
        heightAnchor.constraint(equalToConstant: 18).isActive = true
        toolTip = color.map(colorName)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1.5, dy: 1.5)
        let path = NSBezierPath(ovalIn: r)
        if let color {
            color.setFill()
            path.fill()
        }
        NSColor.labelColor.withAlphaComponent(color == nil ? 0.25 : 0.3).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        if let color { onPick?(color, event.modifierFlags.contains(.control)) }
    }

    override func rightMouseDown(with event: NSEvent) {
        if let color { onPick?(color, true) }
    }
}

func colorName(_ color: NSColor) -> String {
    let c = color.usingColorSpace(.sRGB) ?? color
    return "Red \(Int((c.redComponent * 255).rounded())), Green \(Int((c.greenComponent * 255).rounded())), "
        + "Blue \(Int((c.blueComponent * 255).rounded()))"
}

/// The big Color 1 / Color 2 circle; the active one has a ring.
final class ColorCircle: NSView {
    var color: NSColor = .black { didSet { needsDisplay = true } }
    var isActive = false { didSet { needsDisplay = true } }
    var action: (() -> Void)?

    init(toolTip: String) {
        super.init(frame: .zero)
        self.toolTip = toolTip
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 36).isActive = true
        heightAnchor.constraint(equalToConstant: 36).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        if isActive {
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
            ring.lineWidth = 2
            NSColor.controlAccentColor.setStroke()
            ring.stroke()
        }
        let path = NSBezierPath(ovalIn: bounds.insetBy(dx: 5, dy: 5))
        color.setFill()
        path.fill()
        NSColor.labelColor.withAlphaComponent(0.3).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    override func mouseDown(with event: NSEvent) { action?() }
}

/// The Edit colors glyph: a color wheel with a plus.
func colorWheelImage(size: CGFloat = 22) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        let center = NSPoint(x: rect.midX, y: rect.midY), radius = size / 2 - 1
        for i in 0..<36 {
            let a0 = CGFloat(i) * 10, a1 = a0 + 10.5
            let path = NSBezierPath()
            path.move(to: center)
            path.appendArc(withCenter: center, radius: radius, startAngle: a0, endAngle: a1)
            path.close()
            NSColor(hue: CGFloat(i) / 36, saturation: 0.85, brightness: 0.95, alpha: 1).setFill()
            path.fill()
        }
        NSColor.white.setFill()
        NSBezierPath(ovalIn: rect.insetBy(dx: size * 0.3, dy: size * 0.3)).fill()
        return true
    }
}
