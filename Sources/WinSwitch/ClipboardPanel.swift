import AppKit
import Carbon.HIToolbox

/// The Win+V panel, laid out like the Windows 11 one: a tab row (emoji, symbols, clipboard), a "Clipboard" header
/// with Clear all, and one card per item with a pin and a "..." menu. A non-activating panel: it takes the keys while
/// open, but the app you were typing in stays active, so the chosen item is pasted straight into it.
@MainActor
final class ClipboardPanel: NSPanel {
    static let shared = ClipboardPanel()

    private static let size = NSSize(width: 360, height: 470)
    private let effect = NSVisualEffectView()
    private let stack = NSStackView()
    private let scroll = NSScrollView()
    private var cards: [ClipboardCard] = []
    private var selected = 0
    /// While a card's "..." menu is open the panel loses key status; it must not close then.
    fileprivate var menuOpen = false

    private init() {
        super.init(contentRect: NSRect(origin: .zero, size: Self.size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false

        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 8
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 1
        effect.layer?.borderColor = NSColor.separatorColor.cgColor
        contentView = effect

        // Tab row. Emoji and symbols open the macOS Character Viewer; the clipboard tab is the current one.
        let tabs = NSStackView(views: [
            tab("face.smiling", "Emoji", #selector(openCharacters), selected: false),
            tab("Ω", "Symbols", #selector(openCharacters), selected: false),
            tab("doc.on.clipboard", "Clipboard history", nil, selected: true),
        ])
        tabs.spacing = 4
        tabs.translatesAutoresizingMaskIntoConstraints = false
        let rule = NSBox()
        rule.boxType = .separator
        rule.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "Clipboard")
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        let clear = NSButton(title: "Clear all", target: self, action: #selector(clearAll))
        clear.isBordered = false
        clear.contentTintColor = .controlAccentColor
        clear.attributedTitle = NSAttributedString(string: "Clear all", attributes: [
            .foregroundColor: NSColor.controlAccentColor, .font: NSFont.systemFont(ofSize: 13)])
        let header = NSStackView(views: [title, NSView(), clear])
        header.translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 14, bottom: 14, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.translatesAutoresizingMaskIntoConstraints = false

        for view in [tabs, rule, header, scroll] as [NSView] { effect.addSubview(view) }
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: effect.topAnchor, constant: 10),
            tabs.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 12),
            rule.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 8),
            rule.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            header.topAnchor.constraint(equalTo: rule.bottomAnchor, constant: 12),
            header.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -14),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])

        ClipboardHistory.shared.onChange = { [weak self] in
            guard let self, self.isVisible else { return }
            self.reload()
        }
    }

    override var canBecomeKey: Bool { true }

    private func tab(_ symbol: String, _ tip: String, _ action: Selector?, selected: Bool) -> NSView {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        let button = image.map { NSButton(image: $0, target: self, action: action) }
            ?? NSButton(title: symbol, target: self, action: action) // plain glyph tabs such as Ω
        button.font = .systemFont(ofSize: 16)
        button.isBordered = false
        button.toolTip = tip
        button.symbolConfiguration = .init(pointSize: 15, weight: .regular)
        button.contentTintColor = selected ? .labelColor : .secondaryLabelColor
        button.translatesAutoresizingMaskIntoConstraints = false
        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 5
        box.layer?.backgroundColor = selected ? NSColor.labelColor.withAlphaComponent(0.08).cgColor : nil
        box.addSubview(button)
        NSLayoutConstraint.activate([
            box.widthAnchor.constraint(equalToConstant: 40), box.heightAnchor.constraint(equalToConstant: 30),
            button.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            button.centerYAnchor.constraint(equalTo: box.centerYAnchor, constant: selected ? -2 : 0),
        ])
        if selected { // the accent underline of the current tab
            let line = NSView()
            line.wantsLayer = true
            line.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
            line.layer?.cornerRadius = 1.5
            line.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(line)
            NSLayoutConstraint.activate([
                line.widthAnchor.constraint(equalToConstant: 16), line.heightAnchor.constraint(equalToConstant: 3),
                line.centerXAnchor.constraint(equalTo: box.centerXAnchor),
                line.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -1),
            ])
        }
        return box
    }

    func toggle() {
        if isVisible { close(); return }
        selected = 0
        reload()
        // Next to the mouse, kept on its screen.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let f = screen?.visibleFrame {
            let x = min(max(mouse.x - Self.size.width / 2, f.minX + 8), f.maxX - Self.size.width - 8)
            let y = min(max(mouse.y - Self.size.height - 12, f.minY + 8), f.maxY - Self.size.height - 8)
            setFrameOrigin(NSPoint(x: x, y: y))
        }
        setContentSize(Self.size)
        makeKeyAndOrderFront(nil)
    }

    override func resignKey() {
        super.resignKey()
        if !menuOpen { close() } // clicking anywhere else closes it, like a menu
    }

    private func reload() {
        let history = ClipboardHistory.shared
        // Pinned first, then most recent first, like Windows.
        let entries = history.entries.filter(\.pinned) + history.entries.filter { !$0.pinned }
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        cards = entries.map { entry in
            let card = ClipboardCard(entry: entry, panel: self)
            card.onPaste = { [weak self] in self?.paste(entry) }
            return card
        }
        if cards.isEmpty {
            let empty = NSTextField(wrappingLabelWithString: "You can't paste from your clipboard history yet.\n\nCopy something and it will show up here. Pin items to keep them.")
            empty.textColor = .secondaryLabelColor
            empty.alignment = .center
            stack.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
        }
        for card in cards {
            stack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
        }
        selected = min(selected, max(cards.count - 1, 0))
        stack.layoutSubtreeIfNeeded()
        if selected == 0 { scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView) }
        highlight()
    }

    private func highlight() {
        for (i, card) in cards.enumerated() { card.isSelected = i == selected }
        if cards.indices.contains(selected) { cards[selected].scrollToVisible(cards[selected].bounds) }
    }

    private func paste(_ entry: ClipboardHistory.Entry) {
        ClipboardHistory.shared.copy(entry)
        close()
        // The previous app is still active; give its window the keys back, then paste.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            Remapper.post(kVK_ANSI_V, [.maskCommand])
        }
    }

    @objc private func clearAll() { ClipboardHistory.shared.clearUnpinned() }

    @objc private func openCharacters() {
        close()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            Remapper.post(kVK_Space, [.maskControl, .maskCommand]) // the system emoji and symbols picker
        }
    }

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case kVK_DownArrow: selected = min(selected + 1, cards.count - 1); highlight()
        case kVK_UpArrow: selected = max(selected - 1, 0); highlight()
        case kVK_Return, kVK_ANSI_KeypadEnter: if cards.indices.contains(selected) { paste(cards[selected].entry) }
        case kVK_Escape: close()
        case kVK_Delete, kVK_ForwardDelete:
            if cards.indices.contains(selected) { ClipboardHistory.shared.delete(cards[selected].entry.id) }
        default: super.keyDown(with: event)
        }
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// One clipboard item as a Windows 11 style card: the content, with a "..." menu and a pin at the top right.
@MainActor
private final class ClipboardCard: NSView {
    /// Card width (360 panel - 2 x 14 margin) minus padding (14 + 8), the two buttons (52) and spacing (8).
    static let textWidth: CGFloat = 332 - 22 - 52 - 8

    let entry: ClipboardHistory.Entry
    weak var panel: ClipboardPanel?
    var onPaste: (() -> Void)?
    var isSelected = false { didSet { updateLook() } }
    private var hovering = false { didSet { updateLook() } }
    private let more = NSButton()

    init(entry: ClipboardHistory.Entry, panel: ClipboardPanel) {
        self.entry = entry
        self.panel = panel
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        translatesAutoresizingMaskIntoConstraints = false

        let preview: NSView
        if let image = entry.image {
            let view = NSImageView(image: image)
            view.imageScaling = .scaleProportionallyDown
            view.imageAlignment = .alignTopLeft
            view.heightAnchor.constraint(equalToConstant: min(110, max(28, image.size.height))).isActive = true
            preview = view
        } else {
            let urls = entry.fileURLs
            let text = urls.isEmpty ? (entry.text ?? "Formatted content")
                                    : urls.map(\.lastPathComponent).joined(separator: "\n")
            let label = NSTextField(wrappingLabelWithString: String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500)))
            label.font = .systemFont(ofSize: 13)
            label.preferredMaxLayoutWidth = Self.textWidth - (urls.isEmpty ? 0 : 40)
            label.maximumNumberOfLines = 4
            label.lineBreakMode = .byWordWrapping
            label.cell?.truncatesLastVisibleLine = true
            if !urls.isEmpty {
                let icon = NSImageView(image: NSWorkspace.shared.icon(forFile: urls[0].path))
                icon.widthAnchor.constraint(equalToConstant: 32).isActive = true
                icon.heightAnchor.constraint(equalToConstant: 32).isActive = true
                let row = NSStackView(views: [icon, label])
                row.alignment = .top
                preview = row
            } else {
                preview = label
            }
        }
        preview.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        preview.setContentHuggingPriority(.defaultLow, for: .horizontal)

        more.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "See more")
        more.toolTip = "See more"
        more.target = self
        more.action = #selector(showMenu)
        let pin = NSButton(image: NSImage(systemSymbolName: entry.pinned ? "pin.fill" : "pin",
                                          accessibilityDescription: entry.pinned ? "Unpin" : "Pin") ?? NSImage(),
                           target: self, action: #selector(togglePin))
        pin.toolTip = entry.pinned ? "Unpin" : "Pin"
        for b in [more, pin] {
            b.isBordered = false
            b.contentTintColor = .secondaryLabelColor
            b.widthAnchor.constraint(equalToConstant: 26).isActive = true
            b.heightAnchor.constraint(equalToConstant: 22).isActive = true
        }
        if entry.pinned { pin.contentTintColor = .labelColor }
        let buttons = NSStackView(views: [more, pin])
        buttons.spacing = 0

        // Content on the left, the "..." and pin buttons fixed in the top right corner.
        preview.translatesAutoresizingMaskIntoConstraints = false
        buttons.translatesAutoresizingMaskIntoConstraints = false
        addSubview(preview)
        addSubview(buttons)
        NSLayoutConstraint.activate([
            buttons.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            buttons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            preview.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            preview.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            preview.trailingAnchor.constraint(lessThanOrEqualTo: buttons.leadingAnchor, constant: -8),
            preview.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -12),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 52),
        ])
        let fit = preview.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12)
        fit.priority = .defaultHigh // as tall as the content needs
        fit.isActive = true
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        updateLook()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func updateLook() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let base: CGFloat = dark ? 0.07 : 0.55
        let fill = dark ? NSColor.white.withAlphaComponent(hovering ? base + 0.04 : base)
                        : NSColor.white.withAlphaComponent(hovering ? base + 0.25 : base)
        layer?.backgroundColor = fill.cgColor
        layer?.borderWidth = isSelected ? 2 : 1
        layer?.borderColor = (isSelected ? NSColor.controlAccentColor : NSColor.separatorColor.withAlphaComponent(0.5)).cgColor
    }

    override func viewDidChangeEffectiveAppearance() { updateLook() }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseUp(with event: NSEvent) { onPaste?() }

    @objc private func togglePin() { ClipboardHistory.shared.togglePin(entry.id) }

    @objc private func showMenu() {
        let menu = NSMenu()
        let delete = NSMenuItem(title: "Delete", action: #selector(deleteEntry), keyEquivalent: "")
        delete.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        let pin = NSMenuItem(title: entry.pinned ? "Unpin" : "Pin", action: #selector(togglePin), keyEquivalent: "")
        pin.image = NSImage(systemSymbolName: entry.pinned ? "pin.slash" : "pin", accessibilityDescription: nil)
        let clear = NSMenuItem(title: "Clear all", action: #selector(clearAll), keyEquivalent: "")
        clear.image = NSImage(systemSymbolName: "clear", accessibilityDescription: nil)
        for item in [delete, pin, clear] { item.target = self; menu.addItem(item) }
        panel?.menuOpen = true
        menu.popUp(positioning: nil, at: NSPoint(x: more.frame.minX, y: more.frame.minY), in: more.superview)
        panel?.menuOpen = false
        panel?.makeKey()
    }

    @objc private func deleteEntry() { ClipboardHistory.shared.delete(entry.id) }
    @objc private func clearAll() { ClipboardHistory.shared.clearUnpinned() }
}
