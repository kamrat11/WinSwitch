import AppKit
import Scintilla
import WinDialogs

/// The Notepad++ main window: toolbar, tabs, the editor, Function List and Document Map on the right, search results
/// at the bottom and the status bar.
@MainActor
final class EditorWindow: NSWindowController, NSWindowDelegate, TabBarDelegate {
    private(set) var documents: [Document] = []
    private(set) var currentIndex = 0
    var current: Document? { documents.indices.contains(currentIndex) ? documents[currentIndex] : nil }
    var editor: ScintillaView? { current?.editor }

    let tabBar = TabBar()
    let toolbar = NSStackView()
    let editorContainer = NSView()
    let outerSplit = NSSplitView()
    let innerSplit = NSSplitView()
    let sidePanel = SidePanel()
    let results = FindResultsPanel()
    let statusBar = NSStackView()
    private var statusFields: [String: NSButton] = [:]
    lazy var macro = MacroRecorder(window: self)
    /// Recently closed files, for File > Restore Recent Closed File.
    var closedFiles: [URL] = []
    private var functionListTimer: Timer?
    private var nextUntitled = 1

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.minSize = NSSize(width: 500, height: 300)
        window.setFrameAutosaveName("WinCodeMain")
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        buildUI()
        if window.frame.origin == .zero { window.center() }
        window.level = Preferences.alwaysOnTop ? .floating : .normal
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Layout

    private func buildUI() {
        guard let content = window?.contentView else { return }
        toolbar.orientation = .horizontal
        toolbar.spacing = 1
        toolbar.edgeInsets = NSEdgeInsets(top: 2, left: 6, bottom: 2, right: 6)
        buildToolbar()
        tabBar.delegate = self

        innerSplit.isVertical = true
        innerSplit.dividerStyle = .thin
        innerSplit.addArrangedSubview(editorContainer)
        innerSplit.addArrangedSubview(sidePanel)
        innerSplit.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        innerSplit.setHoldingPriority(.defaultHigh, forSubviewAt: 1)
        sidePanel.owner = self

        outerSplit.isVertical = false
        outerSplit.dividerStyle = .thin
        outerSplit.addArrangedSubview(innerSplit)
        outerSplit.addArrangedSubview(results)
        outerSplit.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        outerSplit.setHoldingPriority(.defaultHigh, forSubviewAt: 1)
        results.owner = self

        statusBar.orientation = .horizontal
        statusBar.spacing = 0
        statusBar.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
        buildStatusBar()

        let stack = NSStackView(views: [toolbar, separator(), tabBar, outerSplit, separator(), statusBar])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        for view in stack.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 30),
            tabBar.heightAnchor.constraint(equalToConstant: 28),
            statusBar.heightAnchor.constraint(equalToConstant: 22),
        ])
        outerSplit.setContentHuggingPriority(.init(1), for: .vertical)
        outerSplit.setContentCompressionResistancePriority(.init(1), for: .vertical)
        results.isHidden = true
        updatePanels()
    }

    private func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    func updatePanels() {
        toolbar.isHidden = !Preferences.showToolbar
        statusBar.isHidden = !Preferences.showStatusBar
        sidePanel.showFunctionList = Preferences.showFunctionList
        sidePanel.showDocumentMap = Preferences.showDocumentMap
        let showSide = Preferences.showFunctionList || Preferences.showDocumentMap
        if sidePanel.isHidden == showSide {
            sidePanel.isHidden = !showSide
            if showSide { innerSplit.setPosition(innerSplit.bounds.width - 260, ofDividerAt: 0) }
        }
        innerSplit.adjustSubviews()
        DispatchQueue.main.async { self.sidePanel.balance() }
        sidePanel.reload()
    }

    func showResults(_ show: Bool) {
        guard results.isHidden == show else { return }
        results.isHidden = !show
        outerSplit.adjustSubviews()
        if show {
            outerSplit.layoutSubtreeIfNeeded()
            outerSplit.setPosition(max(150, outerSplit.bounds.height - 220), ofDividerAt: 0)
        }
    }

    // MARK: Toolbar

    private func buildToolbar() {
        let items: [(String, String, Selector)] = [
            ("doc.badge.plus", "New", #selector(newDocument(_:))),
            ("folder", "Open", #selector(openDocument(_:))),
            ("square.and.arrow.down", "Save", #selector(saveDocument(_:))),
            ("square.and.arrow.down.on.square", "Save All", #selector(saveAll(_:))),
            ("xmark.square", "Close", #selector(closeTab(_:))),
            ("xmark.square.fill", "Close All", #selector(closeAll(_:))),
            ("printer", "Print", #selector(printDocument(_:))),
            ("|", "", #selector(noop)),
            ("scissors", "Cut", #selector(NSText.cut(_:))),
            ("doc.on.doc", "Copy", #selector(NSText.copy(_:))),
            ("doc.on.clipboard", "Paste", #selector(NSText.paste(_:))),
            ("|", "", #selector(noop)),
            ("arrow.uturn.backward", "Undo", Selector(("undo:"))),
            ("arrow.uturn.forward", "Redo", Selector(("redo:"))),
            ("|", "", #selector(noop)),
            ("magnifyingglass", "Find", #selector(showFind(_:))),
            ("arrow.left.arrow.right", "Replace", #selector(showReplace(_:))),
            ("|", "", #selector(noop)),
            ("plus.magnifyingglass", "Zoom In", #selector(zoomIn(_:))),
            ("minus.magnifyingglass", "Zoom Out", #selector(zoomOut(_:))),
            ("|", "", #selector(noop)),
            ("text.word.spacing", "Word wrap", #selector(toggleWordWrap(_:))),
            ("paragraphsign", "Show All Characters", #selector(toggleAllCharacters(_:))),
            ("increase.indent", "Show Indent Guide", #selector(toggleIndentGuides(_:))),
            ("|", "", #selector(noop)),
            ("list.bullet.indent", "Function List", #selector(toggleFunctionList(_:))),
            ("map", "Document Map", #selector(toggleDocumentMap(_:))),
            ("|", "", #selector(noop)),
            ("record.circle", "Start Recording", #selector(startRecording(_:))),
            ("stop.circle", "Stop Recording", #selector(stopRecording(_:))),
            ("play.circle", "Playback", #selector(playMacro(_:))),
            ("forward.end.circle", "Run a Macro Multiple Times...", #selector(runMacroMultiple(_:))),
            ("square.and.arrow.down.badge.clock", "Save Current Recorded Macro", #selector(saveMacro(_:))),
        ]
        for (symbol, title, action) in items {
            if symbol == "|" {
                let line = NSBox()
                line.boxType = .separator
                line.translatesAutoresizingMaskIntoConstraints = false
                line.heightAnchor.constraint(equalToConstant: 18).isActive = true
                toolbar.addArrangedSubview(line)
                toolbar.setCustomSpacing(5, after: toolbar.arrangedSubviews[toolbar.arrangedSubviews.count - 2])
                toolbar.setCustomSpacing(5, after: line)
                continue
            }
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
                ?? NSImage(systemSymbolName: "square", accessibilityDescription: title)!
            let button = NSButton(image: image, target: nil, action: action)
            button.bezelStyle = .toolbar
            button.isBordered = false
            button.toolTip = title
            button.imageScaling = .scaleProportionallyDown
            button.symbolConfiguration = .init(pointSize: 13, weight: .regular)
            button.contentTintColor = toolbarTint(symbol)
            button.widthAnchor.constraint(equalToConstant: 26).isActive = true
            button.heightAnchor.constraint(equalToConstant: 24).isActive = true
            toolbar.addArrangedSubview(button)
        }
    }

    private func toolbarTint(_ symbol: String) -> NSColor? {
        switch symbol {
        case "doc.badge.plus", "folder": return .systemYellow
        case "square.and.arrow.down", "square.and.arrow.down.on.square": return .systemBlue
        case "xmark.square", "xmark.square.fill", "record.circle": return .systemRed
        case "play.circle", "forward.end.circle": return .systemGreen
        case "magnifyingglass", "arrow.left.arrow.right", "plus.magnifyingglass", "minus.magnifyingglass": return .systemIndigo
        default: return nil
        }
    }

    @objc private func noop() {}

    // MARK: Status bar

    private func buildStatusBar() {
        let fields: [(String, CGFloat, Selector?)] = [
            ("language", 220, #selector(languageMenuFromStatus(_:))), ("length", 200, nil), ("position", 230, #selector(goToLine(_:))),
            ("eol", 120, #selector(eolMenuFromStatus(_:))), ("encoding", 110, #selector(encodingMenuFromStatus(_:))), ("mode", 40, nil),
        ]
        for (index, (key, width, action)) in fields.enumerated() {
            let button = NSButton(title: "", target: self, action: action)
            button.isBordered = false
            button.font = .systemFont(ofSize: 11)
            button.alignment = .left
            button.lineBreakMode = .byTruncatingTail
            button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            if key == "language" {
                button.setContentHuggingPriority(.defaultLow, for: .horizontal)
                button.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
            } else {
                button.widthAnchor.constraint(equalToConstant: width).isActive = true
            }
            statusFields[key] = button
            if index > 0 {
                let line = NSBox()
                line.boxType = .separator
                line.translatesAutoresizingMaskIntoConstraints = false
                line.heightAnchor.constraint(equalToConstant: 14).isActive = true
                statusBar.addArrangedSubview(line)
                statusBar.setCustomSpacing(6, after: line)
                statusBar.setCustomSpacing(6, after: statusBar.arrangedSubviews[statusBar.arrangedSubviews.count - 2])
            }
            statusBar.addArrangedSubview(button)
        }
    }

    func updateStatus() {
        guard let doc = current else { return }
        let e = doc.editor
        let pos = e.currentPos
        let line = e.line(of: pos)
        let col = e.send(SCI_GETCOLUMN, pos) + 1
        let selStart = e.selectionStart, selEnd = e.selectionEnd
        let selChars = e.send(SCI_COUNTCHARACTERS, selStart, selEnd)
        let selLines = selEnd > selStart ? e.line(of: selEnd) - e.line(of: selStart) + 1 : 0
        let numbers = NumberFormatter()
        numbers.numberStyle = .decimal
        func n(_ v: Int) -> String { numbers.string(from: NSNumber(value: v)) ?? "\(v)" }
        statusFields["language"]?.title = doc.language == .normal ? "Normal text file" : "\(doc.language.name) file"
        statusFields["length"]?.title = "length : \(n(e.length))    lines : \(n(e.lineCount))"
        statusFields["position"]?.title = "Ln : \(n(line + 1))    Col : \(n(col))    Pos : \(n(pos + 1))    Sel : \(n(selChars)) | \(n(selLines))"
        statusFields["eol"]?.title = doc.eol.title
        statusFields["encoding"]?.title = doc.encoding.title
        statusFields["mode"]?.title = e.send(SCI_GETOVERTYPE) != 0 ? "OVR" : "INS"
    }

    @objc private func languageMenuFromStatus(_ sender: NSButton) {
        let menu = MainMenu.languageMenu()
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
    }

    @objc private func eolMenuFromStatus(_ sender: NSButton) {
        let menu = NSMenu()
        for eol in EOL.allCases {
            let item = NSMenuItem(title: eol.title, action: #selector(convertEOL(_:)), keyEquivalent: "")
            item.representedObject = eol.rawValue
            item.target = self
            item.state = current?.eol == eol ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
    }

    @objc private func encodingMenuFromStatus(_ sender: NSButton) {
        let menu = MainMenu.encodingMenu()
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
    }

    // MARK: Documents

    @discardableResult
    func addDocument(select: Bool = true) -> Document {
        let doc = Document(owner: self)
        doc.untitledNumber = nextUntitled
        nextUntitled += 1
        insert(doc, select: select)
        return doc
    }

    private func insert(_ doc: Document, select: Bool) {
        let at = documents.isEmpty ? 0 : currentIndex + 1
        documents.insert(doc, at: at)
        refreshTabs()
        if select { self.select(at) }
    }

    /// Opens files; a file that is already open is just selected. Returns the last document.
    @discardableResult
    func open(_ urls: [URL]) -> Document? {
        var last: Document?
        for url in urls {
            let url = url.standardizedFileURL
            if let index = documents.firstIndex(where: { $0.url?.standardizedFileURL == url }) {
                select(index)
                last = documents[index]
                continue
            }
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                let files = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
                last = open(files.filter { !$0.hasDirectoryPath }.sorted { $0.path < $1.path }) ?? last
                continue
            }
            // Replace a single untouched "new 1" tab, like Notepad++.
            let replace = documents.count == 1 && documents[0].url == nil && !documents[0].isModified && documents[0].editor.length == 0
            let doc = Document(owner: self)
            do {
                if !FileManager.default.fileExists(atPath: url.path) {
                    let alert = NSAlert()
                    alert.messageText = "\"\(url.path)\" doesn't exist. Create it?"
                    alert.addButton(withTitle: "Yes")
                    alert.addButton(withTitle: "No")
                    guard alert.runModal() == .alertFirstButtonReturn else { continue }
                    try Data().write(to: url)
                }
                try doc.load(url)
            } catch {
                NSAlert(error: error).runModal()
                continue
            }
            if replace {
                documents = []
                currentIndex = 0
            }
            insert(doc, select: true)
            Preferences.addRecent(url.path)
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            last = doc
        }
        return last
    }

    func select(_ index: Int) {
        guard documents.indices.contains(index) else { return }
        current?.editor.removeFromSuperview()
        currentIndex = index
        let doc = documents[index]
        doc.editor.frame = editorContainer.bounds
        doc.editor.autoresizingMask = [.width, .height]
        editorContainer.addSubview(doc.editor)
        window?.makeFirstResponder(doc.editor.content())
        tabBar.selected = index
        updateTitle()
        updateStatus()
        sidePanel.reload()
        checkExternalChange(doc)
    }

    /// After restoring a session, new tabs continue the "new N" numbering.
    func renumberUntitled() {
        nextUntitled = (documents.filter { $0.url == nil }.map(\.untitledNumber).max() ?? 0) + 1
    }

    /// Puts the same documents in a new order (Window > Sort By).
    func reorder(_ newOrder: [Document]) {
        let selected = current
        documents = newOrder
        currentIndex = documents.firstIndex { $0 === selected } ?? 0
        refreshTabs()
    }

    func refreshTabs() {
        tabBar.tabs = documents.map { TabBar.Tab(title: $0.name, modified: $0.isModified, readOnly: $0.readOnly, tooltip: $0.url?.path ?? $0.name) }
        tabBar.selected = currentIndex
    }

    func documentChanged(_ doc: Document) {
        refreshTabs()
        if doc === current {
            updateTitle()
            updateStatus()
        }
    }

    private func updateTitle() {
        guard let doc = current else { window?.title = "Notepad++"; return }
        window?.title = (doc.isModified ? "*" : "") + (doc.url?.path ?? doc.name) + " - Notepad++"
        window?.representedURL = doc.url
        window?.isDocumentEdited = doc.isModified
    }

    /// Notepad++ asks when the file changed on disk while it was open.
    func checkExternalChange(_ doc: Document) {
        guard let url = doc.url, let known = doc.fileDate else { return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            doc.fileDate = nil
            let alert = NSAlert()
            alert.messageText = "\"\(url.path)\" doesn't exist anymore."
            alert.informativeText = "Keep this file in the editor?"
            alert.addButton(withTitle: "Keep")
            alert.addButton(withTitle: "Close")
            if alert.runModal() == .alertSecondButtonReturn, let index = documents.firstIndex(where: { $0 === doc }) {
                remove(at: index)
            }
            return
        }
        guard let date = Document.modificationDate(url), date > known.addingTimeInterval(0.5) else { return }
        doc.fileDate = date
        let alert = NSAlert()
        alert.messageText = "Reload"
        alert.informativeText = "\"\(url.path)\"\n\nThis file has been modified by another program.\nDo you want to reload it\(doc.isModified ? " and lose the changes made in Notepad++" : "")?"
        alert.addButton(withTitle: "Yes")
        alert.addButton(withTitle: "No")
        if alert.runModal() == .alertFirstButtonReturn { reload(doc) }
    }

    func reload(_ doc: Document, encoding: TextEncoding? = nil) {
        guard let url = doc.url else { return }
        let line = doc.editor.send(SCI_GETFIRSTVISIBLELINE)
        let pos = doc.editor.currentPos
        do {
            try doc.load(url, encoding: encoding)
            doc.editor.send(SCI_GOTOPOS, min(pos, doc.editor.length))
            doc.editor.send(SCI_SETFIRSTVISIBLELINE, line)
        } catch {
            NSAlert(error: error).runModal()
        }
        documentChanged(doc)
    }

    // MARK: Saving and closing

    @discardableResult
    func save(_ doc: Document) -> Bool {
        guard let url = doc.url else { return saveAs(doc) }
        do {
            try doc.save(to: url)
            documentChanged(doc)
            return true
        } catch {
            NSAlert(error: error).runModal()
            return false
        }
    }

    @discardableResult
    func saveAs(_ doc: Document, copy: Bool = false) -> Bool {
        // Notepad++'s "Save as type" list: every language with its extensions, then all types.
        let languages = Language.all.filter { !$0.extensions.isEmpty }
        let dialog = SaveDialog()
        dialog.title = copy ? "Save a Copy As" : "Save As"
        dialog.types = languages.map { SaveDialog.FileType($0 == .normal ? "Normal text file" : "\($0.name) file", $0.extensions) }
            + [SaveDialog.FileType("All types", [])]
        dialog.typeIndex = doc.url == nil ? languages.firstIndex(of: doc.language) ?? 0 : languages.count
        dialog.fileName = doc.url?.lastPathComponent ?? doc.name
        dialog.directory = doc.url?.deletingLastPathComponent() ?? current?.url?.deletingLastPathComponent()
        dialog.rememberKey = "saveFolder"
        guard let result = dialog.run() else { return false }
        let url = result.url
        if copy {
            guard let data = doc.encoding.encode(doc.editor.text) else { return false }
            do { try data.write(to: url, options: .atomic) } catch { NSAlert(error: error).runModal(); return false }
            return true
        }
        do {
            try doc.save(to: url)
            Preferences.addRecent(url.path)
            documentChanged(doc)
            return true
        } catch {
            NSAlert(error: error).runModal()
            return false
        }
    }

    /// Asks to save a modified document. Returns false when the user cancels.
    func confirmClose(_ doc: Document) -> Bool {
        guard doc.isModified else { return true }
        if let index = documents.firstIndex(where: { $0 === doc }) { select(index) }
        let alert = NSAlert()
        alert.messageText = "Save file \"\(doc.url?.path ?? doc.name)\"?"
        alert.addButton(withTitle: "Yes")
        alert.addButton(withTitle: "No")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save(doc)
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }

    @discardableResult
    func close(at index: Int) -> Bool {
        guard documents.indices.contains(index), confirmClose(documents[index]) else { return false }
        remove(at: index)
        return true
    }

    private func remove(at index: Int) {
        let doc = documents[index]
        if let url = doc.url { closedFiles.append(url) }
        doc.editor.removeFromSuperview()
        documents.remove(at: index)
        if documents.isEmpty {
            nextUntitled = 1
            addDocument()
            return
        }
        if index < currentIndex { currentIndex -= 1 }
        currentIndex = min(currentIndex, documents.count - 1)
        refreshTabs()
        select(currentIndex)
    }

    /// Closes the documents for which `keep` is false; stops at the first cancel.
    @discardableResult
    func closeDocuments(where shouldClose: (Int, Document) -> Bool) -> Bool {
        let targets = documents.enumerated().filter { shouldClose($0.offset, $0.element) }.map(\.element)
        for doc in targets {
            guard let index = documents.firstIndex(where: { $0 === doc }) else { continue }
            if !close(at: index) { return false }
        }
        return true
    }

    // MARK: Window

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.terminate(nil)
        return false
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if let doc = current { checkExternalChange(doc) }
    }

    // MARK: Tabs

    func tabBar(_ bar: TabBar, select index: Int) { select(index) }
    func tabBar(_ bar: TabBar, close index: Int) { close(at: index) }
    func tabBarNewTab(_ bar: TabBar) { addDocument() }

    func tabBar(_ bar: TabBar, move from: Int, to: Int) {
        let doc = documents.remove(at: from)
        documents.insert(doc, at: to)
        currentIndex = to
        refreshTabs()
    }

    func tabBar(_ bar: TabBar, menuFor index: Int) -> NSMenu? {
        MainMenu.tabMenu()
    }

    // MARK: Notifications from the editors

    func editorNotification(_ doc: Document, _ scn: SCNotification) {
        let e = doc.editor
        switch Int32(scn.nmhdr.code) {
        case SCN_SAVEPOINTREACHED, SCN_SAVEPOINTLEFT:
            documentChanged(doc)
        case SCN_UPDATEUI:
            guard doc === current else { return }
            updateStatus()
            Editing.matchBraces(e)
            if scn.updated & Int32(SC_UPDATE_SELECTION) != 0 { Editing.smartHighlight(e) }
            sidePanel.editorScrolled()
        case SCN_CHARADDED:
            Editing.charAdded(doc, Int(scn.ch))
        case SCN_MARGINCLICK where scn.margin == 1:
            Editing.toggleBookmark(e, line: e.line(of: scn.position))
        case SCN_MODIFIED:
            if scn.linesAdded != 0 { doc.updateMargins() }
            if doc === current { scheduleFunctionList() }
        case SCN_MACRORECORD:
            macro.record(scn)
        case SCN_URIDROPPED:
            if let path = scn.text.map({ String(cString: $0) }) {
                DispatchQueue.main.async { self.open([URL(fileURLWithPath: path)]) }
            }
        case SCN_ZOOM:
            doc.updateMargins()
        default:
            break
        }
    }

    private func scheduleFunctionList() {
        guard Preferences.showFunctionList || Preferences.showDocumentMap else { return }
        functionListTimer?.invalidate()
        functionListTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.sidePanel.reload() }
        }
    }
}
