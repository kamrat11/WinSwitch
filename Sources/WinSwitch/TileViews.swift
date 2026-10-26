import AppKit

/// One window: thumbnail (or the app icon until one arrives), app icon badge and title. The app icon carries the
/// app's Dock badge, and a window that rang the bell gets an orange bell and frame.
final class WindowTile: NSView {
    static let thumbSize = NSSize(width: 220, height: 138)
    static let size = NSSize(width: thumbSize.width + 16, height: thumbSize.height + 46)

    let info: WindowInfo
    var onClick: (() -> Void)?
    var onHover: (() -> Void)?
    /// The Mac's red, yellow and green window buttons, shown in the thumbnail's top-left corner while the mouse is
    /// on the tile (Dock previews only).
    var onClose: (() -> Void)?
    var onToggleMinimize: (() -> Void)?
    var onZoom: (() -> Void)?
    var showsControls = false

    /// Starts as the window's state and follows the minimize / restore button.
    var isMinimized: Bool { didSet { updateMinimized() } }

    var isSelected = false { didSet { updateHighlight() } }

    private let thumbView = NSImageView()
    private let badge = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let dockBadge = NSTextField(labelWithString: "")
    private let bell = NSImageView()
    private let closeButton = TileButton(color: NSColor(srgbRed: 1.0, green: 0.37, blue: 0.34, alpha: 1), symbol: "xmark", toolTip: "Close")
    private let minimizeButton = TileButton(color: NSColor(srgbRed: 1.0, green: 0.74, blue: 0.18, alpha: 1), symbol: "minus", toolTip: "Minimize")
    private let zoomButton = TileButton(color: NSColor(srgbRed: 0.16, green: 0.78, blue: 0.25, alpha: 1), symbol: "plus", toolTip: "Full screen")

    init(window: WindowInfo, image: NSImage?) {
        self.info = window
        self.isMinimized = window.isMinimized
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        wantsLayer = true
        layer?.cornerRadius = 10

        thumbView.frame = NSRect(x: 8, y: 38, width: Self.thumbSize.width, height: Self.thumbSize.height)
        thumbView.imageScaling = .scaleProportionallyUpOrDown
        thumbView.wantsLayer = true
        thumbView.layer?.cornerRadius = 6
        addSubview(thumbView)

        badge.frame = NSRect(x: 8, y: 8, width: 22, height: 22)
        badge.image = window.app.icon
        addSubview(badge)

        titleLabel.frame = NSRect(x: 36, y: 9, width: Self.size.width - 44, height: 18)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = .labelColor
        titleLabel.toolTip = "\(window.appName): \(window.title)"
        addSubview(titleLabel)

        dockBadge.font = .systemFont(ofSize: 9, weight: .bold)
        dockBadge.textColor = .white
        dockBadge.alignment = .center
        dockBadge.wantsLayer = true
        dockBadge.layer?.backgroundColor = NSColor.systemRed.cgColor
        dockBadge.layer?.cornerRadius = 7
        dockBadge.layer?.masksToBounds = true
        if let label = Attention.shared.badge(for: window.app) {
            // On the icon's top-right corner, like the Dock's own badge.
            dockBadge.stringValue = String(label.prefix(3))
            let width = max(14, ceil(dockBadge.intrinsicContentSize.width) + 4)
            dockBadge.frame = NSRect(x: badge.frame.maxX + 4 - width, y: badge.frame.maxY - 8, width: width, height: 14)
            dockBadge.toolTip = "\(window.appName): \(label) on its Dock icon"
            addSubview(dockBadge)
        }

        if Attention.shared.isAlerting(window.id) {
            thumbView.layer?.borderWidth = 2
            thumbView.layer?.borderColor = NSColor.systemOrange.cgColor
            bell.frame = NSRect(x: thumbView.frame.maxX - 28, y: thumbView.frame.maxY - 28, width: 22, height: 22)
            bell.wantsLayer = true
            bell.layer?.backgroundColor = NSColor.systemOrange.cgColor
            bell.layer?.cornerRadius = 11
            bell.imageScaling = .scaleNone
            bell.contentTintColor = .white
            bell.image = NSImage(systemSymbolName: "bell.fill", accessibilityDescription: "Rang the bell")?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .bold))
            bell.toolTip = "This window rang the bell"
            addSubview(bell)
        }

        closeButton.onPress = { [weak self] in self?.onClose?() }
        minimizeButton.onPress = { [weak self] in self?.onToggleMinimize?() }
        zoomButton.onPress = { [weak self] in self?.onZoom?() }
        // Same order and corner as on a Mac window: red, yellow, green from the left.
        for (i, button) in [closeButton, minimizeButton, zoomButton].enumerated() {
            button.setFrameOrigin(NSPoint(x: thumbView.frame.minX + 6 + CGFloat(i) * (TileButton.side + 6),
                                          y: thumbView.frame.maxY - TileButton.side - 6))
            button.isHidden = true
            addSubview(button)
        }

        setImage(image)
        updateMinimized()
        updateHighlight()
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    func setImage(_ image: NSImage?) {
        if let image {
            thumbView.image = image
            thumbView.imageScaling = .scaleProportionallyUpOrDown
            thumbView.alphaValue = isMinimized ? 0.55 : 1
        } else {
            // No thumbnail yet (or no Screen Recording permission): show a large app icon instead.
            let icon = (info.app.icon?.copy() as? NSImage) ?? NSImage()
            icon.size = NSSize(width: 72, height: 72)
            thumbView.image = icon
            thumbView.imageScaling = .scaleNone
            thumbView.alphaValue = 1
        }
    }

    private func updateMinimized() {
        titleLabel.stringValue = isMinimized ? "\(info.displayTitle) (minimized)" : info.displayTitle
        minimizeButton.toolTip = isMinimized ? "Restore" : "Minimize"
        zoomButton.toolTip = isMinimized ? "Restore" : "Full screen"
        if thumbView.imageScaling != .scaleNone { thumbView.alphaValue = isMinimized ? 0.55 : 1 }
    }

    /// Shows the buttons if the mouse is on the tile. Called after the tiles move under a resting mouse, which
    /// sends no mouseEntered.
    func refreshHover() {
        guard let window else { return }
        let inside = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
        setControlsVisible(inside)
        if inside { onHover?() }
    }

    private func setControlsVisible(_ visible: Bool) {
        for button in [closeButton, minimizeButton, zoomButton] { button.isHidden = !(visible && showsControls) }
    }

    private func updateHighlight() {
        layer?.backgroundColor = isSelected ? NSColor.controlAccentColor.withAlphaComponent(0.45).cgColor : NSColor.clear.cgColor
    }

    override func mouseEntered(with event: NSEvent) {
        setControlsVisible(true)
        onHover?()
    }
    override func mouseExited(with event: NSEvent) { setControlsVisible(false) }
    override func mouseUp(with event: NSEvent) { onClick?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// One of the Mac's round window buttons (red, yellow or green) on a tile's thumbnail.
final class TileButton: NSView {
    static let side: CGFloat = 16

    var onPress: (() -> Void)?

    private let color: NSColor
    private let imageView = NSImageView()
    private var isHovered = false { didSet { render() } }

    init(color: NSColor, symbol: String, toolTip: String) {
        self.color = color
        super.init(frame: NSRect(x: 0, y: 0, width: Self.side, height: Self.side))
        wantsLayer = true
        layer?.cornerRadius = Self.side / 2
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.black.withAlphaComponent(0.25).cgColor
        imageView.frame = bounds
        imageView.imageScaling = .scaleNone
        imageView.contentTintColor = NSColor.black.withAlphaComponent(0.6)
        imageView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: toolTip)?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .heavy))
        addSubview(imageView)
        self.toolTip = toolTip
        render()
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    private func render() {
        layer?.backgroundColor = (isHovered ? color.blended(withFraction: 0.2, of: .black) ?? color : color).cgColor
    }

    override var isHidden: Bool { didSet { if isHidden { isHovered = false } } }

    // The button takes the whole click itself, so the tile under it does not also switch to the window.
    override func hitTest(_ point: NSPoint) -> NSView? { !isHidden && frame.contains(point) ? self : nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?() }
    }
}

/// Lays tiles out left to right, wrapping into rows that fit `maxWidth`.
final class TileGrid: NSView {
    static let spacing: CGFloat = 8
    static let padding: CGFloat = 14

    private(set) var tiles: [WindowTile] = []

    override var isFlipped: Bool { true }

    func setTiles(_ tiles: [WindowTile], maxWidth: CGFloat) {
        self.tiles.forEach { $0.removeFromSuperview() }
        self.tiles = tiles
        let tile = WindowTile.size
        let perRow = max(1, Int((maxWidth - 2 * Self.padding + Self.spacing) / (tile.width + Self.spacing)))
        let columns = min(perRow, tiles.count)
        let rows = (tiles.count + perRow - 1) / perRow
        for (i, view) in tiles.enumerated() {
            let row = i / perRow, column = i % perRow
            view.setFrameOrigin(NSPoint(x: Self.padding + CGFloat(column) * (tile.width + Self.spacing),
                                        y: Self.padding + CGFloat(row) * (tile.height + Self.spacing)))
            addSubview(view)
        }
        setFrameSize(NSSize(width: 2 * Self.padding + CGFloat(columns) * tile.width + CGFloat(max(0, columns - 1)) * Self.spacing,
                            height: 2 * Self.padding + CGFloat(rows) * tile.height + CGFloat(max(0, rows - 1)) * Self.spacing))
    }
}

/// Borderless floating panel with a blurred background, shared by the switcher and Dock previews.
final class FloatingPanel: NSPanel {
    let grid = TileGrid()
    private let effect = NSVisualEffectView()

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false

        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 16
        effect.layer?.masksToBounds = true
        effect.addSubview(grid)
        contentView = effect
    }

    override var canBecomeKey: Bool { false }

    /// Fills the grid and resizes the panel to fit it.
    func show(tiles: [WindowTile], maxWidth: CGFloat) {
        grid.setTiles(tiles, maxWidth: maxWidth)
        setContentSize(grid.frame.size)
        effect.frame = NSRect(origin: .zero, size: grid.frame.size)
        grid.setFrameOrigin(.zero)
    }
}
