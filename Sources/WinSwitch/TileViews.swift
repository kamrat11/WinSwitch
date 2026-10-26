import AppKit

/// One window: thumbnail (or the app icon until one arrives), app icon badge and title.
final class WindowTile: NSView {
    static let thumbSize = NSSize(width: 220, height: 138)
    static let size = NSSize(width: thumbSize.width + 16, height: thumbSize.height + 46)

    let info: WindowInfo
    var onClick: (() -> Void)?
    var onHover: (() -> Void)?

    var isSelected = false { didSet { updateHighlight() } }

    private let thumbView = NSImageView()
    private let badge = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")

    init(window: WindowInfo, image: NSImage?) {
        self.info = window
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
        titleLabel.stringValue = window.isMinimized ? "\(window.displayTitle) (minimized)" : window.displayTitle
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = .labelColor
        titleLabel.toolTip = "\(window.appName): \(window.title)"
        addSubview(titleLabel)

        setImage(image)
        updateHighlight()
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    func setImage(_ image: NSImage?) {
        if let image {
            thumbView.image = image
            thumbView.imageScaling = .scaleProportionallyUpOrDown
            thumbView.alphaValue = info.isMinimized ? 0.55 : 1
        } else {
            // No thumbnail yet (or no Screen Recording permission): show a large app icon instead.
            let icon = (info.app.icon?.copy() as? NSImage) ?? NSImage()
            icon.size = NSSize(width: 72, height: 72)
            thumbView.image = icon
            thumbView.imageScaling = .scaleNone
        }
    }

    private func updateHighlight() {
        layer?.backgroundColor = isSelected ? NSColor.controlAccentColor.withAlphaComponent(0.45).cgColor : NSColor.clear.cgColor
    }

    override func mouseEntered(with event: NSEvent) { onHover?() }
    override func mouseUp(with event: NSEvent) { onClick?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
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
