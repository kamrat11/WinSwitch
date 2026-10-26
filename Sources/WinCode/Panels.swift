import AppKit
import Scintilla

/// The "Search results" panel at the bottom: one node per search, files under it, matching lines under those.
/// Double-click a line to jump to it.
@MainActor
final class FindResultsPanel: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    final class Node {
        let title: NSAttributedString
        var children: [Node] = []
        var url: URL?
        weak var document: Document?
        var position: (Int, Int)?
        var line: Int?
        init(_ title: NSAttributedString) { self.title = title }
    }

    weak var owner: EditorWindow?
    private var roots: [Node] = []
    private let outline = NSOutlineView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        let header = NSTextField(labelWithString: "Search results")
        header.font = .systemFont(ofSize: 11, weight: .semibold)
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")!, target: self, action: #selector(closePanel))
        close.isBordered = false
        let clear = NSButton(title: "Clear all", target: self, action: #selector(clearAll))
        clear.isBordered = false
        clear.font = .systemFont(ofSize: 11)
        let bar = NSStackView(views: [header, NSView(), clear, close])
        bar.edgeInsets = NSEdgeInsets(top: 2, left: 8, bottom: 2, right: 8)

        let column = NSTableColumn(identifier: .init("text"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowHeight = 17
        outline.style = .plain
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(jump)
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true

        let stack = NSStackView(views: [bar, scroll])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            bar.widthAnchor.constraint(equalTo: stack.widthAnchor), scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 60),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private static func styled(_ text: String, color: NSColor = .labelColor, bold: Bool = false) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: bold ? NSFont.monospacedSystemFont(ofSize: 11, weight: .bold) : NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: color])
    }

    /// A line of a match, with the match itself highlighted.
    private static func lineTitle(_ number: Int, _ line: String, highlight: Range<String.Index>?) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: styled("Line \(number): ", color: .secondaryLabelColor))
        let trimmed = String(line.prefix(400))
        let body = NSMutableAttributedString(attributedString: styled(trimmed))
        if let highlight, highlight.upperBound <= trimmed.endIndex {
            body.addAttributes([.backgroundColor: NSColor.systemYellow.withAlphaComponent(0.5), .foregroundColor: NSColor.labelColor],
                               range: NSRange(highlight, in: trimmed))
        }
        result.append(body)
        return result
    }

    @discardableResult
    func add(search o: SearchOptions, documents: [Document]) -> Int {
        var total = 0
        let root = Node(NSAttributedString())
        for doc in documents {
            let e = doc.editor
            let hits = Search.findAll(e, o, limit: 20_000)
            guard !hits.isEmpty else { continue }
            total += hits.count
            let file = Node(Self.styled("  \(doc.url?.path ?? doc.name) (\(hits.count) hit\(hits.count == 1 ? "" : "s"))", color: .systemGreen, bold: true))
            file.document = doc
            for (start, end) in hits {
                let line = e.line(of: start)
                let lineStart = e.lineStart(line)
                let text = e.lineText(line)
                let prefixCount = e.text(from: lineStart, to: start).count
                let matchCount = e.text(from: start, to: min(end, e.lineEnd(line))).count
                let lower = text.index(text.startIndex, offsetBy: min(prefixCount, text.count))
                let upper = text.index(lower, offsetBy: min(matchCount, text.distance(from: lower, to: text.endIndex)))
                let node = Node(Self.lineTitle(line + 1, text, highlight: lower..<upper))
                node.document = doc
                node.position = (start, end)
                file.children.append(node)
            }
            root.children.append(file)
        }
        let title = Node(Self.styled("Search \"\(o.text)\" (\(total) hits in \(root.children.count) file\(root.children.count == 1 ? "" : "s") of \(documents.count) searched)",
                                     color: .systemBlue, bold: true))
        title.children = root.children
        show(title)
        return total
    }

    /// Searches (and optionally replaces in) files on disk; open documents are searched in their editors.
    func addFiles(search o: SearchOptions, files: [URL], replace: Bool) -> (hits: Int, files: Int) {
        let root = Node(NSAttributedString())
        var total = 0
        let scratch = ScintillaView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        scratch.send(SCI_SETCODEPAGE, Int(SC_CP_UTF8))
        for url in files {
            let open = owner?.documents.first { $0.url?.standardizedFileURL == url.standardizedFileURL }
            let e: ScintillaView
            var encoding = TextEncoding.utf8
            if let open {
                e = open.editor
            } else {
                guard let data = try? Data(contentsOf: url), !data.prefix(8000).contains(0) || TextEncoding.detect(data) == .utf16LE
                        || TextEncoding.detect(data) == .utf16BE else { continue }
                encoding = TextEncoding.detect(data)
                scratch.text = encoding.decode(data) ?? ""
                e = scratch
            }
            if replace {
                let count = Search.replaceAll(e, o)
                if count > 0 {
                    total += count
                    root.children.append(Node(Self.styled("  \(url.path) (\(count) replaced)", color: .systemGreen, bold: true)))
                    if open == nil, let data = encoding.encode(e.text) { try? data.write(to: url, options: .atomic) }
                }
                continue
            }
            let hits = Search.findAll(e, o, limit: 5000)
            guard !hits.isEmpty else { continue }
            total += hits.count
            let file = Node(Self.styled("  \(url.path) (\(hits.count) hit\(hits.count == 1 ? "" : "s"))", color: .systemGreen, bold: true))
            file.url = url
            file.document = open
            var lastLine = -1
            for (start, _) in hits {
                let line = e.line(of: start)
                guard line != lastLine else { continue }
                lastLine = line
                let node = Node(Self.lineTitle(line + 1, e.lineText(line), highlight: nil))
                node.url = url
                node.document = open
                node.line = line
                if open != nil { node.position = (start, start) }
                file.children.append(node)
            }
            root.children.append(file)
        }
        let verb = replace ? "Replace" : "Search"
        let title = Node(Self.styled("\(verb) \"\(o.text)\" (\(total) hits in \(root.children.count) files of \(files.count) searched)", color: .systemBlue, bold: true))
        title.children = root.children
        show(title)
        return (total, root.children.count)
    }

    private func show(_ node: Node) {
        roots.insert(node, at: 0)
        outline.reloadData()
        outline.expandItem(node, expandChildren: true)
        for old in roots.dropFirst() { outline.collapseItem(old) }
        outline.scrollRowToVisible(0)
        owner?.showResults(true)
    }

    @objc private func jump() {
        guard let node = outline.item(atRow: outline.clickedRow) as? Node, let owner else { return }
        if let doc = node.document, let index = owner.documents.firstIndex(where: { $0 === doc }) {
            owner.select(index)
        } else if let url = node.url {
            owner.open([url])
        } else {
            return
        }
        guard let e = owner.editor else { return }
        if let (start, end) = node.position, node.document != nil {
            e.send(SCI_ENSUREVISIBLEENFORCEPOLICY, e.line(of: start))
            e.select(start, end)
            e.send(SCI_VERTICALCENTRECARET)
        } else if let line = node.line {
            e.goTo(line: line)
        }
        owner.window?.makeFirstResponder(e.content())
    }

    @objc private func closePanel() { owner?.showResults(false) }

    @objc private func clearAll() {
        roots = []
        outline.reloadData()
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? Node)?.children.count ?? roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? Node)?.children[index] ?? roots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? Node)?.children.isEmpty ?? true)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? {
            let c = NSTableCellView()
            c.identifier = id
            let t = NSTextField(labelWithString: "")
            t.lineBreakMode = .byTruncatingTail
            t.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(t)
            c.textField = t
            NSLayoutConstraint.activate([t.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
                                         t.trailingAnchor.constraint(equalTo: c.trailingAnchor),
                                         t.centerYAnchor.constraint(equalTo: c.centerYAnchor)])
            return c
        }()
        cell.textField?.attributedStringValue = (item as? Node)?.title ?? NSAttributedString()
        return cell
    }
}

/// The right-hand panel: Function List (from the language's function pattern) and Document Map (a zoomed-out view
/// of the same document; click or drag in it to scroll).
@MainActor
final class SidePanel: NSSplitView, NSTableViewDataSource, NSTableViewDelegate, ScintillaNotificationProtocol {
    weak var owner: EditorWindow?
    var showFunctionList = false { didSet { functionArea.isHidden = !showFunctionList } }
    var showDocumentMap = false { didSet { mapArea.isHidden = !showDocumentMap } }

    private let functionArea = NSView()
    private let mapArea = NSView()
    private let functionTable = NSTableView()
    private let functionSearch = NSSearchField()
    private var functions: [(name: String, line: Int)] = []
    private var shownFunctions: [(name: String, line: Int)] = []
    private let map = ScintillaView(frame: NSRect(x: 0, y: 0, width: 200, height: 300))
    private let viewport = PassThroughView()
    private weak var mappedDocument: Document?

    override init(frame: NSRect) {
        super.init(frame: frame)
        isVertical = false
        dividerStyle = .thin

        // Function List.
        let title = NSTextField(labelWithString: "Function List")
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        functionSearch.placeholderString = "Search"
        functionSearch.controlSize = .small
        functionSearch.target = self
        functionSearch.action = #selector(filterFunctions)
        let column = NSTableColumn(identifier: .init("name"))
        functionTable.addTableColumn(column)
        functionTable.headerView = nil
        functionTable.rowHeight = 18
        functionTable.style = .plain
        functionTable.dataSource = self
        functionTable.delegate = self
        functionTable.target = self
        functionTable.action = #selector(functionClicked)
        let scroll = NSScrollView()
        scroll.documentView = functionTable
        scroll.hasVerticalScroller = true
        let stack = NSStackView(views: [title, functionSearch, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 0, right: 6)
        pin(stack, in: functionArea)
        functionSearch.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -12).isActive = true
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        // Document Map.
        let mapTitle = NSTextField(labelWithString: "Document Map")
        mapTitle.font = .systemFont(ofSize: 11, weight: .semibold)
        map.delegate = self
        map.send(SCI_SETZOOM, -8)
        map.send(SCI_SETREADONLY, 1)
        map.send(SCI_SETCARETSTYLE, Int(CARETSTYLE_INVISIBLE))
        map.send(SCI_SETHSCROLLBAR, 0)
        map.send(SCI_SETVSCROLLBAR, 0)
        for margin in 0..<5 { map.send(SCI_SETMARGINWIDTHN, margin, 0) }
        map.send(SCI_SETCURSOR, Int(SC_CURSORARROW))
        viewport.wantsLayer = true
        viewport.layer?.borderWidth = 1
        map.addSubview(viewport)
        let mapStack = NSStackView(views: [mapTitle, map])
        mapStack.orientation = .vertical
        mapStack.alignment = .leading
        mapStack.spacing = 4
        mapStack.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 0, right: 0)
        pin(mapStack, in: mapArea)
        map.widthAnchor.constraint(equalTo: mapStack.widthAnchor, constant: -6).isActive = true

        addArrangedSubview(functionArea)
        addArrangedSubview(mapArea)
        widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    private func pin(_ view: NSView, in container: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor), view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor), view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    /// Splits the panel between Function List and Document Map when both are shown.
    func balance() {
        guard showFunctionList && showDocumentMap, mapArea.frame.height < 60 || functionArea.frame.height < 60 else { return }
        layoutSubtreeIfNeeded()
        setPosition(bounds.height * 0.45, ofDividerAt: 0)
    }

    func reload() {
        guard let doc = owner?.current, !isHidden else { return }
        if showFunctionList { reloadFunctions(doc) }
        if showDocumentMap { reloadMap(doc) }
    }

    // MARK: Function List

    private func reloadFunctions(_ doc: Document) {
        functions = []
        if let pattern = doc.language.functionPattern, let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) {
            let text = doc.editor.text
            let ns = text as NSString
            var lineStarts: [Int] = [0]
            for (i, unit) in text.utf16.enumerated() where unit == 10 { lineStarts.append(i + 1) }
            let keywords: Set<String> = ["if", "for", "while", "switch", "return", "catch", "else", "sizeof", "do"]
            for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).prefix(5000) {
                guard let range = (1..<match.numberOfRanges).lazy.map({ match.range(at: $0) }).first(where: { $0.location != NSNotFound }) else { continue }
                let name = ns.substring(with: range).trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty, !keywords.contains(name) else { continue }
                var low = 0, high = lineStarts.count - 1
                while low < high {
                    let mid = (low + high + 1) / 2
                    if lineStarts[mid] <= range.location { low = mid } else { high = mid - 1 }
                }
                functions.append((name, low))
            }
        }
        filterFunctions()
    }

    @objc private func filterFunctions() {
        let query = functionSearch.stringValue.lowercased()
        shownFunctions = query.isEmpty ? functions : functions.filter { $0.name.lowercased().contains(query) }
        functionTable.reloadData()
    }

    @objc private func functionClicked() {
        let row = functionTable.clickedRow
        guard shownFunctions.indices.contains(row), let e = owner?.editor else { return }
        e.goTo(line: shownFunctions[row].line)
        owner?.window?.makeFirstResponder(e.content())
    }

    func numberOfRows(in tableView: NSTableView) -> Int { shownFunctions.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView()
        let image = NSImageView(image: NSImage(systemSymbolName: "f.cursive", accessibilityDescription: nil)!)
        image.contentTintColor = .systemPurple
        let text = NSTextField(labelWithString: shownFunctions[row].name)
        text.font = .systemFont(ofSize: 12)
        text.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [image, text])
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                                     stack.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor),
                                     stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        return cell
    }

    // MARK: Document Map

    private func reloadMap(_ doc: Document) {
        if mappedDocument !== doc {
            mappedDocument = doc
            map.send(SCI_SETDOCPOINTER, 0, doc.editor.send(SCI_GETDOCPOINTER))
            map.send(SCI_SETILEXER, 0, Int(bitPattern: ScintillaCreateLexer(doc.language.lexer)))
            for (index, words) in doc.language.keywords.enumerated() where !words.isEmpty { map.send(SCI_SETKEYWORDS, index, text: words) }
        }
        // Same colours as the editor.
        for style in 0..<256 {
            map.send(SCI_STYLESETFORE, style, doc.editor.send(SCI_STYLEGETFORE, style))
            map.send(SCI_STYLESETBACK, style, doc.editor.send(SCI_STYLEGETBACK, style))
            map.send(SCI_STYLESETFONT, style, text: Preferences.fontName)
        }
        map.send(SCI_SETWRAPMODE, doc.editor.send(SCI_GETWRAPMODE))
        for margin in 0..<5 { map.send(SCI_SETMARGINWIDTHN, margin, 0) }
        map.send(SCI_SETREADONLY, 1)
        map.appearance = doc.editor.appearance
        map.send(SCI_COLOURISE, 0, -1)
        editorScrolled()
    }

    /// Shades the part of the map that the editor shows and keeps it in view. The shade is an overlay: line markers
    /// would belong to the shared document and show up in the editor too.
    func editorScrolled() {
        guard showDocumentMap, !isHidden, let e = owner?.editor, let content = map.content() else { return }
        let firstVisible = e.send(SCI_GETFIRSTVISIBLELINE)
        let first = e.send(SCI_DOCLINEFROMVISIBLE, firstVisible)
        let last = e.send(SCI_DOCLINEFROMVISIBLE, firstVisible + e.send(SCI_LINESONSCREEN))
        // Keep the shaded part in the middle of the map.
        let mapLines = map.send(SCI_LINESONSCREEN)
        let middle = (first + last) / 2
        map.send(SCI_SETFIRSTVISIBLELINE, max(0, map.send(SCI_VISIBLEFROMDOCLINE, middle) - mapLines / 2))
        let lineHeight = CGFloat(map.send(SCI_TEXTHEIGHT, 0))
        let top = CGFloat(map.send(SCI_POINTYFROMPOSITION, 0, map.lineStart(first)))
        let bottom = CGFloat(map.send(SCI_POINTYFROMPOSITION, 0, map.lineStart(min(last, map.lineCount - 1)))) + lineHeight
        let visible = content.visibleRect
        let rect = NSRect(x: visible.minX, y: visible.minY + top, width: visible.width, height: max(lineHeight, bottom - top))
        viewport.frame = content.convert(rect, to: map)
        viewport.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
        viewport.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.25).cgColor
    }

    nonisolated func notification(_ notification: UnsafeMutablePointer<SCNotification>!) {
        let code = Int32(notification.pointee.nmhdr.code)
        guard code == SCN_UPDATEUI else { return }
        MainActor.assumeIsolated {
            // A click in the map moves the caret there: scroll the editor to that line.
            guard let e = owner?.editor, NSEvent.pressedMouseButtons & 1 != 0 else { return }
            let line = map.line(of: map.currentPos)
            let onScreen = e.send(SCI_LINESONSCREEN)
            e.send(SCI_SETFIRSTVISIBLELINE, max(0, e.send(SCI_VISIBLEFROMDOCLINE, line) - onScreen / 2))
            editorScrolled()
        }
    }
}

/// A view that never takes clicks, so they reach the view under it.
final class PassThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
