import AppKit

/// The inline Find and Replace bar at the top of the editor, like Windows 11 Notepad: a chevron that shows the
/// replace row, the find field, previous/next arrows, an options menu (Match case, Wrap around) and a close button.
@MainActor
final class FindBar: NSView, NSSearchFieldDelegate {
    /// Shared by all tabs, like Notepad's last search.
    static var matchCase = UserDefaults.standard.bool(forKey: "findMatchCase") {
        didSet { UserDefaults.standard.set(matchCase, forKey: "findMatchCase") }
    }
    static var wrapAround = UserDefaults.standard.object(forKey: "findWrapAround") as? Bool ?? true {
        didSet { UserDefaults.standard.set(wrapAround, forKey: "findWrapAround") }
    }
    static var lastSearch = ""

    let findField = NSSearchField()
    let replaceField = NSTextField()
    private let chevron = NSButton()
    private let replaceRow = NSStackView()
    private let message = NSTextField(labelWithString: "")

    var onFind: ((_ forward: Bool, _ incremental: Bool) -> Void)?
    var onReplace: (() -> Void)?
    var onReplaceAll: (() -> Void)?
    var onClose: (() -> Void)?

    var showsReplace: Bool {
        get { !replaceRow.isHidden }
        set {
            replaceRow.isHidden = !newValue
            chevron.image = NSImage(systemSymbolName: newValue ? "chevron.up" : "chevron.down", accessibilityDescription: "Toggle replace")
        }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true

        chevron.bezelStyle = .accessoryBarAction
        chevron.isBordered = false
        chevron.target = self
        chevron.action = #selector(toggleReplace)
        chevron.toolTip = "Toggle replace"

        findField.placeholderString = "Find"
        findField.delegate = self
        findField.sendsSearchStringImmediately = true
        replaceField.placeholderString = "Replace"
        replaceField.delegate = self
        for field in [findField, replaceField] as [NSTextField] {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 260).isActive = true
            field.controlSize = .regular
        }

        let previous = symbolButton("arrow.up", "Find previous (Shift+F3)", #selector(findPrevious))
        let next = symbolButton("arrow.down", "Find next (F3)", #selector(findNext))
        let options = symbolButton("textformat", "Options", #selector(showOptions(_:)))
        let close = symbolButton("xmark", "Close (Esc)", #selector(close))
        message.textColor = .secondaryLabelColor
        message.font = .systemFont(ofSize: 11)

        let findRow = NSStackView()
        findRow.setViews([chevron, findField, next, previous, options, message], in: .leading)
        findRow.setViews([close], in: .trailing)
        findRow.spacing = 6
        let replace = NSButton(title: "Replace", target: self, action: #selector(replaceOne))
        let replaceAll = NSButton(title: "Replace all", target: self, action: #selector(replaceEverything))
        for row in [replace, replaceAll] { row.bezelStyle = .rounded; row.controlSize = .regular }
        replaceRow.setViews([replaceField, replace, replaceAll], in: .leading)
        replaceRow.setViews([NSView()], in: .trailing)
        replaceRow.edgeInsets = NSEdgeInsets(top: 0, left: 22, bottom: 0, right: 0)
        replaceRow.spacing = 6

        let stack = NSStackView(views: [findRow, replaceRow])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let border = NSBox()
        border.boxType = .separator
        border.translatesAutoresizingMaskIntoConstraints = false
        addSubview(border)
        NSLayoutConstraint.activate([
            border.leadingAnchor.constraint(equalTo: leadingAnchor),
            border.trailingAnchor.constraint(equalTo: trailingAnchor),
            border.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        showsReplace = false
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    override var wantsUpdateLayer: Bool { true }

    private func symbolButton(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: self, action: action)
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.toolTip = tip
        return button
    }

    func setMessage(_ text: String) { message.stringValue = text }

    @objc private func toggleReplace() { showsReplace.toggle() }
    @objc private func findNext() { FindBar.lastSearch = findField.stringValue; onFind?(true, false) }
    @objc private func findPrevious() { FindBar.lastSearch = findField.stringValue; onFind?(false, false) }
    @objc private func close() { onClose?() }
    @objc private func replaceOne() { FindBar.lastSearch = findField.stringValue; onReplace?() }
    @objc private func replaceEverything() { FindBar.lastSearch = findField.stringValue; onReplaceAll?() }

    @objc private func showOptions(_ sender: NSButton) {
        let menu = NSMenu()
        let matchCase = menu.addItem(withTitle: "Match case", action: #selector(toggleMatchCase), keyEquivalent: "")
        matchCase.target = self
        matchCase.state = FindBar.matchCase ? .on : .off
        let wrap = menu.addItem(withTitle: "Wrap around", action: #selector(toggleWrap), keyEquivalent: "")
        wrap.target = self
        wrap.state = FindBar.wrapAround ? .on : .off
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }

    @objc private func toggleMatchCase() { FindBar.matchCase.toggle(); onFind?(true, true) }
    @objc private func toggleWrap() { FindBar.wrapAround.toggle() }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSTextField) === findField else { return }
        FindBar.lastSearch = findField.stringValue
        onFind?(true, true)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            FindBar.lastSearch = findField.stringValue
            if control === replaceField { onReplace?(); return true }
            onFind?(!(NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false), false)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        default:
            return false
        }
    }
}
