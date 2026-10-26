import AppKit

@MainActor
protocol TabBarDelegate: AnyObject {
    func tabBar(_ bar: TabBar, select index: Int)
    func tabBar(_ bar: TabBar, close index: Int)
    func tabBar(_ bar: TabBar, move from: Int, to: Int)
    func tabBar(_ bar: TabBar, menuFor index: Int) -> NSMenu?
    func tabBarNewTab(_ bar: TabBar)
}

/// Notepad++-style tabs: a disk icon (blue saved, red modified, grey read-only), the name, a close button and an
/// orange line on the active tab. Drag to reorder, middle-click to close, double-click the empty area for a new tab.
@MainActor
final class TabBar: NSView {
    struct Tab {
        var title: String
        var modified: Bool
        var readOnly: Bool
        var tooltip: String
    }

    weak var delegate: TabBarDelegate?
    var tabs: [Tab] = [] { didSet { layoutTabs() } }
    var selected = 0 { didSet { needsDisplay = true; scrollToSelected() } }

    private var frames: [NSRect] = []
    private var offset: CGFloat = 0
    private var hoverIndex: Int?
    private var hoverClose = false
    private var dragFrom: Int?
    private var pressedClose: Int?
    private static let height: CGFloat = 28
    private let font = NSFont.systemFont(ofSize: 12)

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Self.height) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        scrollToSelected()
    }

    private func layoutTabs() {
        var x: CGFloat = 0
        frames = tabs.map { tab in
            let width = min(240, max(90, (tab.title as NSString).size(withAttributes: [.font: font]).width + 56))
            defer { x += width - 1 }
            return NSRect(x: x, y: 2, width: width, height: Self.height - 2)
        }
        toolTip = nil
        removeAllToolTips()
        for (i, frame) in frames.enumerated() { addToolTip(frame, owner: tabs[i].tooltip as NSString, userData: nil) }
        scrollToSelected()
        needsDisplay = true
    }

    private func scrollToSelected() {
        guard frames.indices.contains(selected), bounds.width > 60 else { return }
        let f = frames[selected]
        if f.maxX - offset > bounds.width - 30 { offset = f.maxX - bounds.width + 30 }
        if f.minX - offset < 0 { offset = f.minX }
        offset = max(0, min(offset, max(0, (frames.last?.maxX ?? 0) - bounds.width + 30)))
        needsDisplay = true
    }

    private func shifted(_ i: Int) -> NSRect { frames[i].offsetBy(dx: -offset, dy: 0) }
    private func closeRect(_ i: Int) -> NSRect {
        let f = shifted(i)
        return NSRect(x: f.maxX - 22, y: f.midY - 8, width: 16, height: 16)
    }
    private func index(at point: NSPoint) -> Int? { frames.indices.first { shifted($0).contains(point) } }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        (dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.90, alpha: 1)).setFill()
        bounds.fill()
        for i in frames.indices {
            let f = shifted(i)
            guard f.intersects(dirtyRect) else { continue }
            let active = i == selected
            let fill: NSColor = active ? (dark ? NSColor(white: 0.24, alpha: 1) : .white)
                : (i == hoverIndex ? (dark ? NSColor(white: 0.21, alpha: 1) : NSColor(white: 0.95, alpha: 1))
                   : (dark ? NSColor(white: 0.18, alpha: 1) : NSColor(white: 0.86, alpha: 1)))
            fill.setFill()
            f.fill()
            NSColor.separatorColor.setStroke()
            let border = NSBezierPath(rect: f.insetBy(dx: 0.5, dy: 0.5))
            border.lineWidth = 1
            border.stroke()
            if active {
                NSColor(srgbRed: 0.98, green: 0.6, blue: 0.1, alpha: 1).setFill()
                NSRect(x: f.minX, y: f.minY, width: f.width, height: 3).fill()
            }
            let tab = tabs[i]
            let symbol = tab.readOnly ? "lock.doc.fill" : "doc.fill"
            let color: NSColor = tab.readOnly ? .systemGray : (tab.modified ? .systemRed : .systemBlue)
            if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .regular).applying(.init(paletteColors: [color]))) {
                image.draw(in: NSRect(x: f.minX + 8 + (12 - image.size.width) / 2, y: f.midY - image.size.height / 2, width: image.size.width, height: image.size.height),
                           from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            let attributes: [NSAttributedString.Key: Any] = [.font: active ? NSFont.systemFont(ofSize: 12, weight: .semibold) : font,
                                                             .foregroundColor: NSColor.labelColor]
            let titleRect = NSRect(x: f.minX + 26, y: f.midY - 8, width: f.width - 52, height: 16)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingMiddle
            var attrs = attributes
            attrs[.paragraphStyle] = paragraph
            (tab.title as NSString).draw(in: titleRect, withAttributes: attrs)
            let close = closeRect(i)
            if i == hoverIndex && hoverClose {
                NSColor.systemRed.setFill()
                NSBezierPath(roundedRect: close, xRadius: 3, yRadius: 3).fill()
            }
            if active || i == hoverIndex {
                let x = NSBezierPath()
                let r = close.insetBy(dx: 4.5, dy: 4.5)
                x.move(to: r.origin); x.line(to: NSPoint(x: r.maxX, y: r.maxY))
                x.move(to: NSPoint(x: r.minX, y: r.maxY)); x.line(to: NSPoint(x: r.maxX, y: r.minY))
                x.lineWidth = 1.5
                (i == hoverIndex && hoverClose ? NSColor.white : NSColor.secondaryLabelColor).setStroke()
                x.stroke()
            }
        }
        // "+" new tab button after the last tab.
        let plus = plusRect
        if plus.minX < bounds.width {
            let p = NSBezierPath()
            p.move(to: NSPoint(x: plus.midX - 5, y: plus.midY)); p.line(to: NSPoint(x: plus.midX + 5, y: plus.midY))
            p.move(to: NSPoint(x: plus.midX, y: plus.midY - 5)); p.line(to: NSPoint(x: plus.midX, y: plus.midY + 5))
            p.lineWidth = 1.5
            NSColor.secondaryLabelColor.setStroke()
            p.stroke()
        }
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    private var plusRect: NSRect {
        let x = (frames.last?.maxX ?? 0) - offset + 4
        return NSRect(x: x, y: 4, width: 22, height: Self.height - 6)
    }

    // MARK: Mouse

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let i = index(at: p)
        let onClose = i.map { closeRect($0).contains(p) } ?? false
        if i != hoverIndex || onClose != hoverClose {
            hoverIndex = i
            hoverClose = onClose
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        hoverIndex = nil
        hoverClose = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let i = index(at: p) else {
            if plusRect.contains(p) || event.clickCount == 2 { delegate?.tabBarNewTab(self) }
            return
        }
        if closeRect(i).contains(p) {
            pressedClose = i
            return
        }
        delegate?.tabBar(self, select: i)
        dragFrom = i
    }

    override func mouseDragged(with event: NSEvent) {
        guard let from = dragFrom else { return }
        let p = convert(event.locationInWindow, from: nil)
        if let to = index(at: p), to != from {
            delegate?.tabBar(self, move: from, to: to)
            dragFrom = to
        }
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let i = pressedClose, closeRect(i).contains(p) { delegate?.tabBar(self, close: i) }
        pressedClose = nil
        dragFrom = nil
    }

    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2, let i = index(at: convert(event.locationInWindow, from: nil)) { delegate?.tabBar(self, close: i) }
    }

    override func scrollWheel(with event: NSEvent) {
        offset = max(0, min(offset - event.scrollingDeltaX - event.scrollingDeltaY, max(0, (frames.last?.maxX ?? 0) - bounds.width + 30)))
        needsDisplay = true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let i = index(at: convert(event.locationInWindow, from: nil)) else { return nil }
        delegate?.tabBar(self, select: i)
        return delegate?.tabBar(self, menuFor: i)
    }
}
