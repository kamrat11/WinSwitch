import AppKit
import Scintilla

/// Search options shared by the Find dialog, Find Next (F3) and Find in Files.
struct SearchOptions {
    enum Mode: Int { case normal, extended, regex }
    var text = ""
    var replacement = ""
    var matchCase = false
    var wholeWord = false
    var wrap = true
    var mode = Mode.normal
    var backward = false
    var inSelection = false

    var flags: Int {
        var f: Int32 = 0
        if matchCase { f |= SCFIND_MATCHCASE }
        if wholeWord { f |= SCFIND_WHOLEWORD }
        if mode == .regex { f |= SCFIND_REGEXP | SCFIND_CXX11REGEX }
        return Int(f)
    }

    /// Extended mode turns \n \r \t \0 \\ \xNN into the characters.
    static func unescape(_ s: String) -> String {
        var out = ""
        var it = s.makeIterator()
        while let ch = it.next() {
            guard ch == "\\", let next = it.next() else { out.append(ch); continue }
            switch next {
            case "n": out.append("\n")
            case "r": out.append("\r")
            case "t": out.append("\t")
            case "0": out.append("\0")
            case "\\": out.append("\\")
            case "x":
                let hex = String([it.next(), it.next()].compactMap { $0 })
                if let v = UInt8(hex, radix: 16) { out.append(Character(UnicodeScalar(v))) }
            default: out.append("\\"); out.append(next)
            }
        }
        return out
    }

    var searchText: String { mode == .extended ? Self.unescape(text) : text }
    var replaceText: String { mode == .extended ? Self.unescape(replacement) : replacement }
}

/// The search engine, on Scintilla's target search.
@MainActor
enum Search {
    static var options = SearchOptions()

    /// Finds the next match from the selection; selects it. Returns false when nothing was found.
    @discardableResult
    static func findNext(_ e: ScintillaView, _ o: SearchOptions) -> Bool {
        let needle = o.searchText
        guard !needle.isEmpty else { return false }
        e.send(SCI_SETSEARCHFLAGS, o.flags)
        let length = e.length
        func search(_ from: Int, _ to: Int) -> (Int, Int)? {
            e.send(SCI_SETTARGETRANGE, from, to)
            let found = e.send(SCI_SEARCHINTARGET, needle.utf8.count, text: needle)
            return found < 0 ? nil : (found, e.send(SCI_GETTARGETEND))
        }
        var hit: (Int, Int)?
        if o.backward {
            hit = search(e.selectionStart, 0)
            if hit == nil && o.wrap { hit = search(length, e.selectionStart) }
        } else {
            hit = search(e.selectionEnd, length)
            // An empty regex match at the caret would repeat forever; step past it.
            if let h = hit, h.0 == h.1, h.0 == e.selectionEnd { hit = search(min(length, h.0 + 1), length) }
            if hit == nil && o.wrap { hit = search(0, e.selectionEnd) }
        }
        guard let (start, end) = hit else { return false }
        e.send(SCI_ENSUREVISIBLEENFORCEPOLICY, e.line(of: start))
        e.select(start, end)
        e.send(SCI_VERTICALCENTRECARET)
        return true
    }

    /// All matches in the range as (start, end).
    static func findAll(_ e: ScintillaView, _ o: SearchOptions, in range: (Int, Int)? = nil, limit: Int = 100_000) -> [(Int, Int)] {
        let needle = o.searchText
        guard !needle.isEmpty else { return [] }
        e.send(SCI_SETSEARCHFLAGS, o.flags)
        let (from0, to) = range ?? (0, e.length)
        var from = from0
        var hits: [(Int, Int)] = []
        while from <= to, hits.count < limit {
            e.send(SCI_SETTARGETRANGE, from, to)
            let found = e.send(SCI_SEARCHINTARGET, needle.utf8.count, text: needle)
            guard found >= 0 else { break }
            let end = e.send(SCI_GETTARGETEND)
            hits.append((found, end))
            from = end > found ? end : found + 1
        }
        return hits
    }

    static func replaceCurrent(_ e: ScintillaView, _ o: SearchOptions) -> Bool {
        let start = e.selectionStart, end = e.selectionEnd
        if end > start {
            // Replace only when the selection is a match.
            e.send(SCI_SETSEARCHFLAGS, o.flags)
            e.send(SCI_SETTARGETRANGE, start, end)
            let found = e.send(SCI_SEARCHINTARGET, o.searchText.utf8.count, text: o.searchText)
            if found == start && e.send(SCI_GETTARGETEND) == end {
                let replacement = o.replaceText
                let length = o.mode == .regex
                    ? e.send(SCI_REPLACETARGETRE, replacement.utf8.count, text: replacement)
                    : e.send(SCI_REPLACETARGET, replacement.utf8.count, text: replacement)
                e.select(start + length, start + length)
            }
        }
        return findNext(e, o)
    }

    @discardableResult
    static func replaceAll(_ e: ScintillaView, _ o: SearchOptions) -> Int {
        let range = o.inSelection && e.selectionEnd > e.selectionStart ? (e.selectionStart, e.selectionEnd) : (0, e.length)
        let needle = o.searchText, replacement = o.replaceText
        guard !needle.isEmpty else { return 0 }
        e.send(SCI_SETSEARCHFLAGS, o.flags)
        var count = 0
        var from = range.0, to = range.1
        e.undoGroup {
            while from <= to {
                e.send(SCI_SETTARGETRANGE, from, to)
                let found = e.send(SCI_SEARCHINTARGET, needle.utf8.count, text: needle)
                guard found >= 0 else { break }
                let oldEnd = e.send(SCI_GETTARGETEND)
                let length = o.mode == .regex
                    ? e.send(SCI_REPLACETARGETRE, replacement.utf8.count, text: replacement)
                    : e.send(SCI_REPLACETARGET, replacement.utf8.count, text: replacement)
                to += length - (oldEnd - found)
                from = found + length + (oldEnd == found ? 1 : 0)
                count += 1
            }
        }
        return count
    }

    /// Mark tab: highlights all matches (and optionally bookmarks their lines).
    static func markAll(_ e: ScintillaView, _ o: SearchOptions, bookmark: Bool, purge: Bool) -> Int {
        e.send(SCI_SETINDICATORCURRENT, Int(Indicator.findMark))
        if purge { e.send(SCI_INDICATORCLEARRANGE, 0, e.length) }
        let range = o.inSelection && e.selectionEnd > e.selectionStart ? (e.selectionStart, e.selectionEnd) : nil
        let hits = findAll(e, o, in: range)
        for (start, end) in hits {
            e.send(SCI_INDICATORFILLRANGE, start, end - start)
            if bookmark { e.send(SCI_MARKERADD, e.line(of: start), Int(Marker.bookmark)) }
        }
        return hits.count
    }

    static func clearMarks(_ e: ScintillaView) {
        e.send(SCI_SETINDICATORCURRENT, Int(Indicator.findMark))
        e.send(SCI_INDICATORCLEARRANGE, 0, e.length)
    }
}

/// Notepad++'s Find / Replace / Find in Files / Mark dialog.
@MainActor
final class FindDialog: NSWindowController, NSWindowDelegate, NSTabViewDelegate {
    static let shared = FindDialog()
    weak var editorWindow: EditorWindow?

    private let tabs = NSTabView()
    private var findFields: [NSComboBox] = []
    private var replaceFields: [NSComboBox] = []
    private let filtersField = NSComboBox()
    private let directoryField = NSComboBox()
    private let subfolders = NSButton(checkboxWithTitle: "In all sub-folders", target: nil, action: nil)
    private let hiddenFolders = NSButton(checkboxWithTitle: "In hidden folders", target: nil, action: nil)
    private var checkboxes: [String: [NSButton]] = [:]
    private var modeButtons: [[NSButton]] = []
    private let status = NSTextField(labelWithString: "")
    private var history: [String] = UserDefaults.standard.stringArray(forKey: "findHistory") ?? []
    private var replaceHistory: [String] = UserDefaults.standard.stringArray(forKey: "replaceHistory") ?? []

    private init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 330),
                            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Find"
        // Like Notepad++ on Windows: stays open behind other apps instead of floating above them.
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        super.init(window: panel)
        panel.delegate = self
        build()
        panel.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    enum Page: Int { case find, replace, findInFiles, mark }

    func show(_ page: Page, owner: EditorWindow) {
        self.editorWindow = owner
        tabs.selectTabViewItem(at: page.rawValue)
        if let e = owner.editor {
            let selected = e.selectedText
            if !selected.isEmpty && !selected.contains("\n") && selected.count < 200 {
                findFields.forEach { $0.stringValue = selected }
            }
            if page == .findInFiles, directoryField.stringValue.isEmpty, let dir = owner.current?.url?.deletingLastPathComponent().path {
                directoryField.stringValue = dir
            }
        }
        showWindow(nil)
        window?.makeFirstResponder(findFields[page.rawValue])
        findFields[page.rawValue].currentEditor()?.selectAll(nil)
        status.stringValue = ""
    }

    // MARK: Building

    private func build() {
        guard let content = window?.contentView else { return }
        tabs.delegate = self
        for (index, title) in ["Find", "Replace", "Find in Files", "Mark"].enumerated() {
            let item = NSTabViewItem(identifier: index)
            item.label = title
            item.view = page(Page(rawValue: index)!)
            tabs.addTabViewItem(item)
        }
        tabs.translatesAutoresizingMaskIntoConstraints = false
        status.translatesAutoresizingMaskIntoConstraints = false
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        content.addSubview(tabs)
        content.addSubview(status)
        NSLayoutConstraint.activate([
            tabs.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            tabs.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            tabs.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            status.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            status.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            status.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 4),
            status.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
        ])
    }

    private func combo() -> NSComboBox {
        let box = NSComboBox()
        box.completes = false
        box.numberOfVisibleItems = 12
        box.addItems(withObjectValues: history)
        return box
    }

    private func label(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.alignment = .right
        return l
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .push
        b.controlSize = .regular
        return b
    }

    private func page(_ page: Page) -> NSView {
        let view = NSView()
        let find = combo()
        find.target = self
        find.action = #selector(findNextClicked(_:))
        findFields.append(find)
        var rows: [[NSView]] = [[label("Find what :"), find]]
        if page == .replace || page == .findInFiles {
            let replace = NSComboBox()
            replace.addItems(withObjectValues: replaceHistory)
            replace.completes = false
            replaceFields.append(replace)
            rows.append([label("Replace with :"), replace])
        } else {
            replaceFields.append(NSComboBox())
        }
        if page == .findInFiles {
            filtersField.stringValue = "*.*"
            filtersField.addItems(withObjectValues: ["*.*", "*.txt", "*.c *.cpp *.h *.hpp", "*.swift", "*.py", "*.js *.ts", "*.html *.css", "*.md"])
            rows.append([label("Filters :"), filtersField])
            let browse = button("...", #selector(browseDirectory))
            let dirRow = NSStackView(views: [directoryField, browse])
            dirRow.spacing = 4
            rows.append([label("Directory :"), dirRow])
            subfolders.state = .on
            rows.append([NSView(), NSStackView(views: [subfolders, hiddenFolders])])
        }
        let grid = NSGridView(views: rows)
        grid.column(at: 0).width = 100
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        for row in 0..<grid.numberOfRows { grid.row(at: row).yPlacement = .center }

        var boxes: [NSButton] = []
        func check(_ title: String, _ key: String) -> NSButton {
            let b = NSButton(checkboxWithTitle: title, target: self, action: #selector(optionChanged(_:)))
            b.identifier = NSUserInterfaceItemIdentifier(key)
            checkboxes[key, default: []].append(b)
            boxes.append(b)
            return b
        }
        var optionViews: [NSView] = []
        if page == .mark {
            optionViews.append(check("Bookmark line", "bookmark"))
            optionViews.append(check("Purge for each search", "purge"))
        }
        if page != .findInFiles {
            if page != .find { optionViews.append(check("In selection", "inSelection")) }
        }
        optionViews.append(check("Match whole word only", "wholeWord"))
        optionViews.append(check("Match case", "matchCase"))
        if page != .findInFiles && page != .mark {
            let wrap = check("Wrap around", "wrap")
            wrap.state = .on
            optionViews.append(wrap)
        }
        let options = NSStackView(views: optionViews)
        options.orientation = .vertical
        options.alignment = .leading
        options.spacing = 4

        let modeTitle = NSTextField(labelWithString: "Search Mode")
        modeTitle.font = .systemFont(ofSize: 11, weight: .semibold)
        modeTitle.textColor = .secondaryLabelColor
        let normal = NSButton(radioButtonWithTitle: "Normal", target: self, action: #selector(modeChanged(_:)))
        let extended = NSButton(radioButtonWithTitle: "Extended (\\n, \\r, \\t, \\0, \\x...)", target: self, action: #selector(modeChanged(_:)))
        let regex = NSButton(radioButtonWithTitle: "Regular expression", target: self, action: #selector(modeChanged(_:)))
        normal.state = .on
        for (i, b) in [normal, extended, regex].enumerated() { b.tag = i }
        modeButtons.append([normal, extended, regex])
        let modes = NSStackView(views: [modeTitle, normal, extended, regex])
        modes.orientation = .vertical
        modes.alignment = .leading
        modes.spacing = 4

        if page == .find || page == .replace {
            options.addArrangedSubview(check("Backward direction", "backward"))
        }
        let bottom = NSStackView(views: [options, modes])
        bottom.alignment = .top
        bottom.spacing = 16

        let left = NSStackView(views: [grid, bottom])
        left.orientation = .vertical
        left.alignment = .leading
        left.spacing = 14

        var buttons: [NSButton] = []
        switch page {
        case .find:
            buttons = [button("Find Next", #selector(findNextClicked(_:))), button("Count", #selector(countClicked)),
                       button("Find All in Current Document", #selector(findAllCurrent)),
                       button("Find All in All Opened Documents", #selector(findAllOpen)), button("Close", #selector(closeClicked))]
        case .replace:
            buttons = [button("Find Next", #selector(findNextClicked(_:))), button("Replace", #selector(replaceClicked)),
                       button("Replace All", #selector(replaceAllClicked)),
                       button("Replace All in All Opened Documents", #selector(replaceAllOpen)), button("Close", #selector(closeClicked))]
        case .findInFiles:
            buttons = [button("Find All", #selector(findInFilesClicked)), button("Replace in Files", #selector(replaceInFilesClicked)),
                       button("Close", #selector(closeClicked))]
        case .mark:
            buttons = [button("Mark All", #selector(markAllClicked)), button("Clear all marks", #selector(clearMarksClicked)),
                       button("Copy Marked Text", #selector(copyMarkedClicked)), button("Close", #selector(closeClicked))]
        }
        buttons.first?.keyEquivalent = "\r"
        let buttonStack = NSStackView(views: buttons)
        buttonStack.orientation = .vertical
        buttonStack.alignment = .leading
        buttonStack.spacing = 6
        for b in buttons { b.widthAnchor.constraint(equalToConstant: 230).isActive = true }

        let row = NSStackView(views: [left, buttonStack])
        row.alignment = .top
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -10),
            row.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            row.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -10),
            find.widthAnchor.constraint(equalToConstant: 300),
        ])
        if page == .findInFiles {
            directoryField.widthAnchor.constraint(equalToConstant: 262).isActive = true
        }
        return view
    }

    // MARK: Options

    /// Keeps the checkboxes of all tabs in sync and returns the options of the visible tab.
    @objc private func optionChanged(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue else { return }
        checkboxes[key]?.forEach { $0.state = sender.state }
    }

    @objc private func modeChanged(_ sender: NSButton) {
        for group in modeButtons { group.forEach { $0.state = $0.tag == sender.tag ? .on : .off } }
    }

    private var pageIndex: Int { tabs.indexOfTabViewItem(tabs.selectedTabViewItem!) }

    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        let i = pageIndex
        window?.title = ["Find", "Replace", "Find in Files", "Mark"][i]
        // Carry the search text across tabs.
        let text = findFields.first { !$0.stringValue.isEmpty }?.stringValue ?? ""
        if findFields[i].stringValue.isEmpty { findFields[i].stringValue = text }
        status.stringValue = ""
    }

    private func checked(_ key: String) -> Bool { checkboxes[key]?.first?.state == .on }

    private func currentOptions() -> SearchOptions {
        var o = SearchOptions()
        let i = pageIndex
        o.text = findFields[i].stringValue
        o.replacement = replaceFields[i].stringValue
        o.matchCase = checked("matchCase")
        o.wholeWord = checked("wholeWord")
        o.wrap = checkboxes["wrap"]?.first?.state != .off
        o.backward = checked("backward")
        o.inSelection = checked("inSelection")
        o.mode = SearchOptions.Mode(rawValue: modeButtons[i].first { $0.state == .on }?.tag ?? 0) ?? .normal
        remember(o)
        return o
    }

    private func remember(_ o: SearchOptions) {
        Search.options = o
        if !o.text.isEmpty {
            history = [o.text] + history.filter { $0 != o.text }
            history = Array(history.prefix(20))
            UserDefaults.standard.set(history, forKey: "findHistory")
            for field in findFields {
                field.removeAllItems()
                field.addItems(withObjectValues: history)
            }
        }
        if !o.replacement.isEmpty {
            replaceHistory = Array(([o.replacement] + replaceHistory.filter { $0 != o.replacement }).prefix(20))
            UserDefaults.standard.set(replaceHistory, forKey: "replaceHistory")
        }
    }

    private func report(_ text: String, error: Bool = false) {
        status.stringValue = text
        status.textColor = error ? .systemRed : .secondaryLabelColor
        if error { NSSound.beep() }
    }

    // MARK: Actions

    @objc private func findNextClicked(_ sender: Any?) {
        guard let e = editorWindow?.editor else { return }
        let o = currentOptions()
        if Search.findNext(e, o) {
            report("")
        } else {
            report("Find: Can't find the text \"\(o.text)\"", error: true)
        }
    }

    @objc private func countClicked() {
        guard let e = editorWindow?.editor else { return }
        let o = currentOptions()
        report("Count: \(Search.findAll(e, o).count) matches.")
    }

    @objc private func findAllCurrent() {
        guard let owner = editorWindow, let doc = owner.current else { return }
        let o = currentOptions()
        let count = owner.results.add(search: o, documents: [doc])
        report("Find All: \(count) hits.")
    }

    @objc private func findAllOpen() {
        guard let owner = editorWindow else { return }
        let o = currentOptions()
        let count = owner.results.add(search: o, documents: owner.documents)
        report("Find All: \(count) hits in \(owner.documents.count) documents.")
    }

    @objc private func replaceClicked() {
        guard let e = editorWindow?.editor else { return }
        let o = currentOptions()
        if !Search.replaceCurrent(e, o) { report("Replace: no more occurrences of \"\(o.text)\"", error: true) }
    }

    @objc private func replaceAllClicked() {
        guard let e = editorWindow?.editor else { return }
        let count = Search.replaceAll(e, currentOptions())
        report("Replace All: \(count) occurrences were replaced.")
    }

    @objc private func replaceAllOpen() {
        guard let owner = editorWindow else { return }
        let o = currentOptions()
        guard ProcessDialogs.confirm("Are you sure you want to replace all occurrences in all opened documents?") else { return }
        let count = owner.documents.reduce(0) { $0 + ($1.readOnly ? 0 : Search.replaceAll($1.editor, o)) }
        report("Replace All: \(count) occurrences were replaced in all opened documents.")
    }

    @objc private func markAllClicked() {
        guard let e = editorWindow?.editor else { return }
        let count = Search.markAll(e, currentOptions(), bookmark: checked("bookmark"), purge: checked("purge"))
        report("Mark: \(count) matches.")
    }

    @objc private func clearMarksClicked() {
        guard let e = editorWindow?.editor else { return }
        Search.clearMarks(e)
        report("")
    }

    @objc private func copyMarkedClicked() {
        guard let e = editorWindow?.editor else { return }
        var parts: [String] = []
        var pos = 0
        while pos < e.length {
            let start = e.send(SCI_INDICATORSTART, Int(Indicator.findMark), pos)
            let end = e.send(SCI_INDICATOREND, Int(Indicator.findMark), start)
            if e.send(SCI_INDICATORVALUEAT, Int(Indicator.findMark), start) != 0 { parts.append(e.text(from: start, to: end)) }
            if end <= pos { break }
            pos = end
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(parts.joined(separator: Editing.eolString(e)), forType: .string)
        report("\(parts.count) marked texts copied.")
    }

    @objc private func browseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url { directoryField.stringValue = url.path }
    }

    @objc private func findInFilesClicked() { filesSearch(replace: false) }
    @objc private func replaceInFilesClicked() {
        guard ProcessDialogs.confirm("Are you sure you want to replace all occurrences in the files of \(directoryField.stringValue)?") else { return }
        filesSearch(replace: true)
    }

    private func filesSearch(replace: Bool) {
        guard let owner = editorWindow else { return }
        let o = currentOptions()
        let dir = URL(fileURLWithPath: (directoryField.stringValue as NSString).expandingTildeInPath)
        let filters = filtersField.stringValue.split(separator: " ").map(String.init)
        report("Searching...")
        let files = FilesSearch.files(in: dir, filters: filters.isEmpty ? ["*.*"] : filters,
                                      subfolders: subfolders.state == .on, hidden: hiddenFolders.state == .on)
        let result = owner.results.addFiles(search: o, files: files, replace: replace)
        report(replace ? "Replace in Files: \(result.hits) occurrences were replaced in \(result.files) files."
                       : "Find in Files: \(result.hits) hits in \(result.files) files of \(files.count) searched.")
    }

    @objc private func closeClicked() { close() }
}

/// Small confirmations.
@MainActor
enum ProcessDialogs {
    static func confirm(_ text: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = text
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// A one-field input box; nil when cancelled.
    static func ask(_ title: String, _ prompt: String, value: String = "", width: CGFloat = 260) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = prompt
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: width, height: 24))
        field.stringValue = value
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }
}

/// Find in Files: walking a folder with Windows-style filters ("*.cpp *.h", "!*.min.js" excludes).
enum FilesSearch {
    static func files(in dir: URL, filters: [String], subfolders: Bool, hidden: Bool) -> [URL] {
        let include = filters.filter { !$0.hasPrefix("!") }
        let exclude = filters.filter { $0.hasPrefix("!") }.map { String($0.dropFirst()) }
        var options: FileManager.DirectoryEnumerationOptions = []
        if !subfolders { options.insert(.skipsSubdirectoryDescendants) }
        if !hidden { options.insert(.skipsHiddenFiles) }
        guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: options) else { return [] }
        var result: [URL] = []
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true,
                  (values.fileSize ?? 0) < 50_000_000 else { continue }
            let name = url.lastPathComponent
            guard include.contains(where: { matches(name, $0) }), !exclude.contains(where: { matches(name, $0) }) else { continue }
            result.append(url)
            if result.count > 20_000 { break }
        }
        return result
    }

    static func matches(_ name: String, _ pattern: String) -> Bool {
        if pattern == "*.*" || pattern == "*" { return true }
        return fnmatch(pattern.lowercased(), name.lowercased(), 0) == 0
    }
}
