import AppKit
import WinDialogs

/// One Notepad tab: a window in a native tab group, with the find bar, the text view and the status bar.
@MainActor
final class Editor: NSWindowController, NSWindowDelegate, NSTextViewDelegate, NSMenuItemValidation {

    // MARK: Opening tabs

    private(set) static var all: [Editor] = []

    /// The editor of the key window, or of the frontmost WinPad window.
    static var front: Editor? {
        (NSApp.keyWindow?.windowController as? Editor)
            ?? NSApp.orderedWindows.lazy.compactMap { $0.windowController as? Editor }.first
    }

    /// Opens a tab with the given contents, in `parent`'s tab group or as a new window.
    @discardableResult
    static func open(_ contents: TextFile.Contents = TextFile.Contents(text: "", encoding: .utf8, lineEnding: .crlf),
                     url: URL? = nil, modified: Bool = false, asTabOf parent: NSWindow? = nil,
                     frame: NSRect? = nil, show: Bool = true) -> Editor {
        let editor = Editor(contents: contents, url: url)
        all.append(editor)
        editor.isModified = modified
        editor.updateTitle()
        guard let window = editor.window else { return editor }
        if let parent {
            window.tabbingMode = .preferred
            parent.addTabbedWindow(window, ordered: .above)
        } else {
            if let frame {
                window.setFrame(frame, display: false)
            } else if let last = all.dropLast().last(where: { $0.window?.isVisible == true })?.window {
                window.setFrameTopLeftPoint(NSPoint(x: last.frame.minX + 26, y: last.frame.maxY - 26))
            } else {
                window.center()
            }
        }
        if show {
            editor.showWindow(nil)
            window.makeFirstResponder(editor.textView)
        } else if parent == nil {
            window.orderFront(nil)
        }
        window.tabbingMode = .preferred
        DispatchQueue.main.async { editor.showTabBar() }
        return editor
    }

    /// Windows 11 Notepad always shows its tab strip, even with one tab.
    func showTabBar() {
        guard let window, window.isVisible, let group = window.tabGroup, !group.isTabBarVisible else { return }
        window.toggleTabBar(nil)
    }

    // MARK: State

    private(set) var url: URL?
    private(set) var encoding: TextEncoding
    private(set) var lineEnding: LineEnding
    private(set) var isModified = false
    private(set) var zoom = 100
    private var closingConfirmed = false

    var displayName: String { url?.lastPathComponent ?? "Untitled" }
    var text: String { textView.string }
    var isEmptyUntitled: Bool { url == nil && !isModified && textView.string.isEmpty }

    // MARK: Views

    let textView: EditorTextView
    private let scrollView = NSScrollView()
    private let findBar = FindBar()
    private let statusBar = StatusBar()

    private init(contents: TextFile.Contents, url: URL?) {
        self.url = url
        encoding = contents.encoding
        lineEnding = contents.lineEnding

        // TextKit 1 handles large plain text files better than TextKit 2.
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        layout.allowsNonContiguousLayout = true
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        layout.addTextContainer(container)
        textView = EditorTextView(frame: .zero, textContainer: container)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.minSize = NSSize(width: 420, height: 240)
        window.tabbingMode = .disallowed
        window.tabbingIdentifier = "WinPad"
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        super.init(window: window)
        window.delegate = self
        buildUI()
        textView.string = contents.text
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        applyPreferences()
        NotificationCenter.default.addObserver(self, selector: #selector(preferencesChanged), name: Preferences.changed, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildUI() {
        let tv = textView
        tv.delegate = self
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.usesFindBar = false
        tv.usesFontPanel = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.isAutomaticDataDetectionEnabled = false
        tv.isAutomaticTextCompletionEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.textContainerInset = NSSize(width: 6, height: 6)
        tv.textColor = .textColor
        tv.backgroundColor = .textBackgroundColor
        tv.drawsBackground = true
        tv.isVerticallyResizable = true
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.autoresizingMask = [.width]
        tv.onZoom = { [weak self] step in self?.setZoom((self?.zoom ?? 100) + step * 10) }
        tv.onEscape = { [weak self] in
            guard let self, !self.findBar.isHidden else { return false }
            self.closeFind()
            return true
        }
        tv.onOpenFiles = { urls in AppDelegate.shared.open(urls) }

        scrollView.documentView = tv
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)

        findBar.isHidden = true
        findBar.onFind = { [weak self] forward, incremental in self?.find(forward: forward, incremental: incremental) }
        findBar.onReplace = { [weak self] in self?.replaceCurrent() }
        findBar.onReplaceAll = { [weak self] in self?.replaceAll() }
        findBar.onClose = { [weak self] in self?.closeFind() }

        statusBar.lineEnding.target = self
        statusBar.lineEnding.action = #selector(lineEndingMenu(_:))
        statusBar.encoding.target = self
        statusBar.encoding.action = #selector(encodingMenu(_:))

        let stack = NSStackView(views: [findBar, scrollView, statusBar])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .width
        stack.distribution = .fill
        window?.contentView = stack
        for view in [findBar, scrollView, statusBar] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }

        let gear = NSButton(image: NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")!,
                            target: AppDelegate.shared, action: #selector(AppDelegate.showSettings(_:)))
        gear.isBordered = false
        gear.toolTip = "Settings"
        gear.frame = NSRect(x: 0, y: 0, width: 36, height: 28)
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = gear
        accessory.layoutAttribute = .trailing
        window?.addTitlebarAccessoryViewController(accessory)
    }

    // MARK: Preferences

    @objc private func preferencesChanged() { applyPreferences() }

    private func applyPreferences() {
        applyFont()
        statusBar.isHidden = !Preferences.statusBar
        applyWordWrap(Preferences.wordWrap)
    }

    private func applyFont() {
        let base = Preferences.font
        let font = NSFont(descriptor: base.fontDescriptor, size: max(2, base.pointSize * CGFloat(zoom) / 100)) ?? base
        textView.font = font
        textView.typingAttributes[.font] = font
        updateStatus()
    }

    private func applyWordWrap(_ wrap: Bool) {
        guard let container = textView.textContainer else { return }
        scrollView.hasHorizontalScroller = !wrap
        textView.isHorizontallyResizable = !wrap
        container.widthTracksTextView = wrap
        if wrap {
            container.containerSize = NSSize(width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
            textView.frame.size.width = scrollView.contentSize.width
        } else {
            container.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        }
        textView.sizeToFit()
    }

    func setZoom(_ percent: Int) {
        zoom = min(500, max(10, percent))
        applyFont()
    }

    // MARK: Title and status

    private func updateTitle() {
        window?.title = (isModified ? "*" : "") + displayName + " - Notepad"
        window?.tab.title = displayName + (isModified ? "  \u{25CF}" : "")
        window?.tab.toolTip = url?.path ?? displayName
        window?.isDocumentEdited = isModified
    }

    private func setModified(_ modified: Bool) {
        guard modified != isModified else { return }
        isModified = modified
        updateTitle()
    }

    private func updateStatus() {
        guard !statusBar.isHidden else { return }
        let ns = textView.string as NSString
        let selection = textView.selectedRange()
        let location = min(selection.location, ns.length)
        let lineStart = ns.lineRange(for: NSRange(location: location, length: 0)).location
        statusBar.update(line: Editor.lineNumber(of: location, in: ns), column: location - lineStart + 1,
                         selected: selection.length, total: ns.length, zoomPercent: zoom,
                         lineEnding: lineEnding, encoding: encoding)
    }

    /// The 1-based line of a character offset, counting "\n" in chunks so large files stay fast.
    static func lineNumber(of location: Int, in ns: NSString) -> Int {
        var count = 1, i = 0
        var buffer = [unichar](repeating: 0, count: 8192)
        while i < location {
            let n = min(buffer.count, location - i)
            ns.getCharacters(&buffer, range: NSRange(location: i, length: n))
            for k in 0..<n where buffer[k] == 10 { count += 1 }
            i += n
        }
        return count
    }

    // MARK: NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        setModified(true)
        updateStatus()
    }

    func textViewDidChangeSelection(_ notification: Notification) { updateStatus() }

    // MARK: Loading

    /// Replaces the contents with a file read from disk (used when the tab was an empty Untitled one).
    func load(_ contents: TextFile.Contents, url: URL) {
        self.url = url
        encoding = contents.encoding
        lineEnding = contents.lineEnding
        textView.string = contents.text
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.undoManager?.removeAllActions()
        isModified = false
        updateTitle()
        updateStatus()
    }

    /// A file whose first line is exactly ".LOG" gets the time and date appended each time it is opened.
    func appendLogStampIfNeeded() {
        let text = textView.string
        guard text == ".LOG" || text.hasPrefix(".LOG\n") else { return }
        let stamp = (text.hasSuffix("\n") ? "" : "\n") + TextFile.timeDate() + "\n"
        let end = (text as NSString).length
        textView.textStorage?.replaceCharacters(in: NSRange(location: end, length: 0), with: stamp)
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        textView.scrollRangeToVisible(textView.selectedRange())
        setModified(true)
        updateStatus()
    }

    func restoreSelection(_ location: Int) {
        let loc = min(location, (textView.string as NSString).length)
        textView.setSelectedRange(NSRange(location: loc, length: 0))
        textView.scrollRangeToVisible(textView.selectedRange())
    }

    // MARK: Saving

    @discardableResult
    func save() -> Bool {
        guard let url else { return saveAs() }
        return write(to: url, encoding: encoding)
    }

    @discardableResult
    func saveAs() -> Bool {
        let dialog = SaveDialog()
        dialog.title = "Save as"
        dialog.fileName = url?.lastPathComponent ?? "*.txt"
        if dialog.fileName == "*.txt" { dialog.fileName = "Untitled.txt" }
        dialog.directory = url?.deletingLastPathComponent()
        dialog.types = [SaveDialog.FileType("Text Documents", ["txt"]), SaveDialog.FileType("All Files", [])]
        dialog.typeIndex = url.map { $0.pathExtension.lowercased() == "txt" || $0.pathExtension.isEmpty ? 0 : 1 } ?? 0
        dialog.extra = ("Encoding", TextEncoding.allCases.map(\.title), TextEncoding.allCases.firstIndex(of: encoding) ?? 0)
        dialog.rememberKey = "saveFolder"
        guard let result = dialog.run() else { return false }
        let chosen = TextEncoding.allCases[result.extraIndex]
        guard write(to: result.url, encoding: chosen) else { return false }
        url = result.url
        updateTitle()
        return true
    }

    private func write(to target: URL, encoding chosen: TextEncoding) -> Bool {
        var chosen = chosen
        let text = textView.string
        if !chosen.canEncode(text) {
            let alert = NSAlert()
            alert.messageText = "This file contains characters that can't be saved in \(chosen.title)."
            alert.informativeText = "Save it as UTF-8 to keep them, or save in \(chosen.title) and lose them."
            alert.addButton(withTitle: "Save as UTF-8")
            alert.addButton(withTitle: "Save as \(chosen.title)")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn: chosen = .utf8
            case .alertSecondButtonReturn: break
            default: return false
            }
        }
        do {
            try TextFile.data(for: text, encoding: chosen, lineEnding: lineEnding).write(to: target, options: .atomic)
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Can't save \(target.lastPathComponent)"
            alert.runModal()
            return false
        }
        encoding = chosen
        Preferences.noteRecent(target)
        setModified(false)
        updateStatus()
        return true
    }

    // MARK: Closing

    /// Asks "Do you want to save changes" for a modified tab. False means Cancel.
    func confirmClose() -> Bool {
        guard isModified else { return true }
        window?.makeKeyAndOrderFront(nil)
        let alert = NSAlert()
        alert.messageText = "Do you want to save changes to \(displayName)?"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't save")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[2].keyEquivalent = "\u{1b}"
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save()
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }

    /// Closes without asking again (the caller already confirmed).
    func closeConfirmed() {
        closingConfirmed = true
        window?.close()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        closingConfirmed || confirmClose()
    }

    func windowWillClose(_ notification: Notification) {
        Editor.all.removeAll { $0 === self }
        NotificationCenter.default.removeObserver(self)
    }

    func windowDidResize(_ notification: Notification) {
        if Preferences.wordWrap { applyWordWrap(true) }
    }

    func windowDidBecomeKey(_ notification: Notification) { showTabBar() }

    // MARK: File menu

    @objc override func newWindowForTab(_ sender: Any?) {
        Editor.open(asTabOf: window)
    }

    @objc func saveDocument(_ sender: Any?) { save() }
    @objc func saveDocumentAs(_ sender: Any?) { saveAs() }

    @objc func closeTab(_ sender: Any?) { window?.performClose(nil) }

    @objc func closeWindow(_ sender: Any?) {
        let editors = (window?.tabbedWindows ?? [window].compactMap { $0 }).compactMap { $0.windowController as? Editor }
        for editor in editors where !editor.confirmClose() { return }
        editors.forEach { $0.closeConfirmed() }
    }

    @objc func printText(_ sender: Any?) {
        let info = AppDelegate.shared.printInfo
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.dictionary()[NSPrintInfo.AttributeKey.headerAndFooter] = true
        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        view.appearance = NSAppearance(named: .aqua)
        view.isRichText = false
        view.string = textView.string
        view.font = Preferences.font
        view.textColor = .black
        view.backgroundColor = .white
        view.isVerticallyResizable = true
        view.textContainer?.widthTracksTextView = true
        view.layoutManager?.ensureLayout(for: view.textContainer!)
        view.sizeToFit()
        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.jobTitle = displayName
        if let window { operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil) } else { operation.run() }
    }

    // MARK: Edit menu

    @objc func searchWithGoogle(_ sender: Any?) {
        let selected = (textView.string as NSString).substring(with: textView.selectedRange())
        let query = selected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, var components = URLComponents(string: "https://www.google.com/search") else { return }
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        if let url = components.url { NSWorkspace.shared.open(url) }
    }

    @objc func insertTimeDate(_ sender: Any?) {
        textView.insertText(TextFile.timeDate(), replacementRange: textView.selectedRange())
    }

    @objc func goToLine(_ sender: Any?) {
        let ns = textView.string as NSString
        let lines = Editor.lineNumber(of: ns.length, in: ns)
        let alert = NSAlert()
        alert.messageText = "Go to line"
        alert.informativeText = "Line number:"
        alert.addButton(withTitle: "Go to")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = String(Editor.lineNumber(of: textView.selectedRange().location, in: ns))
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let line = Int(field.stringValue.trimmingCharacters(in: .whitespaces)), line >= 1, line <= lines else {
            let error = NSAlert()
            error.messageText = "The line number is beyond the total number of lines"
            error.runModal()
            return
        }
        var location = 0
        for _ in 1..<line {
            let r = ns.range(of: "\n", options: .literal, range: NSRange(location: location, length: ns.length - location))
            location = r.upperBound
        }
        textView.setSelectedRange(NSRange(location: location, length: 0))
        textView.scrollRangeToVisible(textView.selectedRange())
        window?.makeFirstResponder(textView)
    }

    @objc func showFonts(_ sender: Any?) {
        NSFontManager.shared.target = textView
        NSFontManager.shared.setSelectedFont(Preferences.font, isMultiple: false)
        NSFontManager.shared.orderFrontFontPanel(sender)
    }

    // MARK: Find and replace

    @objc func showFind(_ sender: Any?) { openFind(replace: false) }
    @objc func showReplace(_ sender: Any?) { openFind(replace: true) }

    @objc func findNextMatch(_ sender: Any?) {
        if FindBar.lastSearch.isEmpty { openFind(replace: false) } else { find(forward: true, incremental: false) }
    }

    @objc func findPreviousMatch(_ sender: Any?) {
        if FindBar.lastSearch.isEmpty { openFind(replace: false) } else { find(forward: false, incremental: false) }
    }

    func openFind(replace: Bool) {
        let selected = (textView.string as NSString).substring(with: textView.selectedRange())
        if !selected.isEmpty, !selected.contains("\n") { FindBar.lastSearch = selected }
        findBar.findField.stringValue = FindBar.lastSearch
        findBar.showsReplace = replace
        findBar.setMessage("")
        findBar.isHidden = false
        window?.makeFirstResponder(replace && !FindBar.lastSearch.isEmpty ? findBar.replaceField : findBar.findField)
        (window?.firstResponder as? NSText)?.selectAll(nil)
    }

    private func closeFind() {
        findBar.isHidden = true
        window?.makeFirstResponder(textView)
    }

    private var compareOptions: NSString.CompareOptions { FindBar.matchCase ? [.literal] : [.literal, .caseInsensitive] }

    @discardableResult
    private func find(forward: Bool, incremental: Bool) -> Bool {
        let term = FindBar.lastSearch
        let ns = textView.string as NSString
        guard !term.isEmpty else { findBar.setMessage(""); return false }
        let selection = textView.selectedRange()
        var found: NSRange
        if forward {
            let start = incremental ? selection.location : selection.upperBound
            found = ns.range(of: term, options: compareOptions, range: NSRange(location: start, length: ns.length - start))
            if found.location == NSNotFound, FindBar.wrapAround {
                found = ns.range(of: term, options: compareOptions)
            }
        } else {
            found = ns.range(of: term, options: compareOptions.union(.backwards), range: NSRange(location: 0, length: selection.location))
            if found.location == NSNotFound, FindBar.wrapAround {
                found = ns.range(of: term, options: compareOptions.union(.backwards))
            }
        }
        guard found.location != NSNotFound else {
            findBar.setMessage("No results")
            if !incremental { NSSound.beep() }
            return false
        }
        findBar.setMessage("")
        textView.setSelectedRange(found)
        textView.scrollRangeToVisible(found)
        textView.showFindIndicator(for: found)
        return true
    }

    private func replaceCurrent() {
        let term = FindBar.lastSearch
        guard !term.isEmpty else { return }
        let ns = textView.string as NSString
        let selection = textView.selectedRange()
        if selection.length > 0, ns.substring(with: selection).compare(term, options: compareOptions) == .orderedSame {
            let replacement = findBar.replaceField.stringValue
            if textView.shouldChangeText(in: selection, replacementString: replacement) {
                textView.textStorage?.replaceCharacters(in: selection, with: replacement)
                textView.didChangeText()
                textView.setSelectedRange(NSRange(location: selection.location + (replacement as NSString).length, length: 0))
            }
        }
        find(forward: true, incremental: false)
    }

    private func replaceAll() {
        let term = FindBar.lastSearch
        guard !term.isEmpty, let storage = textView.textStorage else { return }
        let ns = textView.string as NSString
        var ranges: [NSRange] = []
        var search = NSRange(location: 0, length: ns.length)
        while true {
            let r = ns.range(of: term, options: compareOptions, range: search)
            if r.location == NSNotFound { break }
            ranges.append(r)
            search = NSRange(location: r.upperBound, length: ns.length - r.upperBound)
        }
        guard !ranges.isEmpty else { findBar.setMessage("No results"); NSSound.beep(); return }
        let replacement = findBar.replaceField.stringValue
        let values = Array(repeating: replacement, count: ranges.count)
        guard textView.shouldChangeText(inRanges: ranges.map { NSValue(range: $0) }, replacementStrings: values) else { return }
        storage.beginEditing()
        for r in ranges.reversed() { storage.replaceCharacters(in: r, with: replacement) }
        storage.endEditing()
        textView.didChangeText()
        findBar.setMessage("\(ranges.count) replaced")
    }

    // MARK: View menu

    @objc func zoomIn(_ sender: Any?) { setZoom(zoom + 10) }
    @objc func zoomOut(_ sender: Any?) { setZoom(zoom - 10) }
    @objc func resetZoom(_ sender: Any?) { setZoom(100) }

    // MARK: Status bar menus

    @objc private func lineEndingMenu(_ sender: NSButton) {
        let menu = NSMenu()
        for ending in LineEnding.allCases {
            let item = menu.addItem(withTitle: ending.title, action: #selector(setLineEnding(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ending.rawValue
            item.state = ending == lineEnding ? .on : .off
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY), in: sender)
    }

    @objc private func encodingMenu(_ sender: NSButton) {
        let menu = NSMenu()
        for enc in TextEncoding.allCases {
            let item = menu.addItem(withTitle: enc.title, action: #selector(setEncoding(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = enc.rawValue
            item.state = enc == encoding ? .on : .off
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY), in: sender)
    }

    @objc private func setLineEnding(_ sender: NSMenuItem) {
        guard let ending = LineEnding(rawValue: sender.representedObject as? String ?? ""), ending != lineEnding else { return }
        lineEnding = ending
        setModified(true)
        updateStatus()
    }

    @objc private func setEncoding(_ sender: NSMenuItem) {
        guard let enc = TextEncoding(rawValue: sender.representedObject as? String ?? ""), enc != encoding else { return }
        encoding = enc
        setModified(true)
        updateStatus()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(searchWithGoogle(_:)): return textView.selectedRange().length > 0
        case #selector(zoomIn(_:)): return zoom < 500
        case #selector(zoomOut(_:)): return zoom > 10
        default: return true
        }
    }
}
