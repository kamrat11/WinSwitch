import AppKit

/// The Settings page (gear in the title bar): app theme, font, word wrap, status bar and what opening WinPad does.
@MainActor
final class SettingsWindow: NSWindowController, NSWindowDelegate {
    private let theme = NSPopUpButton()
    private let fontButton = NSButton(title: "", target: nil, action: nil)
    private let wordWrap = NSSwitch()
    private let statusBar = NSSwitch()
    private let restore = NSButton(radioButtonWithTitle: "Open content from a previous session", target: nil, action: nil)
    private let fresh = NSButton(radioButtonWithTitle: "Start new session and discard unsaved changes", target: nil, action: nil)

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        build()
        refresh()
        window.center()
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: Preferences.changed, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        for t in Preferences.Theme.allCases { theme.addItem(withTitle: t.title) }
        theme.target = self
        theme.action = #selector(themeChanged)
        fontButton.bezelStyle = .rounded
        fontButton.target = self
        fontButton.action = #selector(chooseFont)
        wordWrap.target = self
        wordWrap.action = #selector(wordWrapChanged)
        statusBar.target = self
        statusBar.action = #selector(statusBarChanged)
        for radio in [restore, fresh] { radio.target = self; radio.action = #selector(openingChanged(_:)) }

        let opening = NSStackView(views: [restore, fresh])
        opening.orientation = .vertical
        opening.alignment = .leading
        opening.spacing = 6

        let stack = NSStackView(views: [
            heading("Appearance"),
            row("App theme", "Select which app theme to display", theme),
            heading("Text Formatting"),
            row("Font", "Family, style and size", fontButton),
            row("Word wrap", "Fit text within the window by default", wordWrap),
            row("Status bar", "Show line, column, zoom, line ending and encoding", statusBar),
            heading("Opening Notepad"),
            row("When Notepad starts", nil, opening),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor),
        ])
        for view in stack.arrangedSubviews where view is NSGridView || view.identifier?.rawValue == "row" {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true
        }
        window?.contentView = content
        let about = NSTextField(labelWithString: "Notepad \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
        about.textColor = .tertiaryLabelColor
        stack.addArrangedSubview(about)
    }

    private func heading(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .boldSystemFont(ofSize: 13)
        return label
    }

    private func row(_ title: String, _ detail: String?, _ control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        let texts = NSStackView(views: [label])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 2
        if let detail {
            let sub = NSTextField(labelWithString: detail)
            sub.font = .systemFont(ofSize: 11)
            sub.textColor = .secondaryLabelColor
            texts.addArrangedSubview(sub)
        }
        let row = NSStackView(views: [texts, NSView(), control])
        row.identifier = NSUserInterfaceItemIdentifier("row")
        row.alignment = control is NSStackView ? .top : .centerY
        return row
    }

    @objc private func refresh() {
        theme.selectItem(at: Preferences.Theme.allCases.firstIndex(of: Preferences.theme) ?? 0)
        let font = Preferences.font
        fontButton.title = "\(font.displayName ?? font.fontName), \(Int(font.pointSize.rounded()))"
        wordWrap.state = Preferences.wordWrap ? .on : .off
        statusBar.state = Preferences.statusBar ? .on : .off
        restore.state = Preferences.restoreSession ? .on : .off
        fresh.state = Preferences.restoreSession ? .off : .on
    }

    @objc private func themeChanged() { Preferences.theme = Preferences.Theme.allCases[theme.indexOfSelectedItem] }
    @objc private func wordWrapChanged() { Preferences.wordWrap = wordWrap.state == .on }
    @objc private func statusBarChanged() { Preferences.statusBar = statusBar.state == .on }
    @objc private func openingChanged(_ sender: NSButton) { Preferences.restoreSession = sender === restore }

    @objc private func chooseFont() {
        NSFontManager.shared.target = self
        NSFontManager.shared.setSelectedFont(Preferences.font, isMultiple: false)
        NSFontManager.shared.orderFrontFontPanel(nil)
    }

    @objc func changeFont(_ sender: Any?) {
        Preferences.font = NSFontManager.shared.convert(Preferences.font)
    }
}
