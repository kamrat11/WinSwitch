import AppKit
import UniformTypeIdentifiers

/// Windows-style File Explorer: address bar, back/forward/up, search, sidebar and a sortable details list.
@MainActor
final class Explorer: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate,
                      NSTextFieldDelegate, NSSearchFieldDelegate, NSMenuDelegate {

    // MARK: Opening windows

    private static var open: [Explorer] = []
    static var hasOpenWindows: Bool { !open.isEmpty }
    /// Files put on the clipboard with Cut, matched to the pasteboard change they were written with.
    static var cut: (urls: [URL], changeCount: Int)?

    static var showHidden: Bool {
        get { UserDefaults.standard.bool(forKey: "explorerShowHidden") }
        set { UserDefaults.standard.set(newValue, forKey: "explorerShowHidden") }
    }

    @discardableResult
    static func openWindow(at folder: URL = FileManager.default.homeDirectoryForCurrentUser, select: URL? = nil,
                           asTabOf parent: NSWindow? = nil) -> Explorer {
        let explorer = Explorer(folder: folder)
        open.append(explorer)
        NSApp.setActivationPolicy(.regular) // show in the Dock and switchers while Explorer is open
        if let parent, let window = explorer.window {
            parent.addTabbedWindow(window, ordered: .above)
        } else {
            explorer.window?.center()
            if let last = open.dropLast().last?.window {
                explorer.window?.setFrameTopLeftPoint(NSPoint(x: last.frame.minX + 24, y: last.frame.maxY - 24))
            }
        }
        explorer.showWindow(nil)
        if let window = explorer.window { Windows.focusOwn(window) }
        if let select { explorer.select([select]) }
        offerFullDiskAccess()
        return explorer
    }

    private static var offeredFullDiskAccess = false
    private static var fullDiskAccessTimer: Timer?

    /// Without Full Disk Access macOS asks for each protected folder separately, so offer it once per launch.
    private static func offerFullDiskAccess() {
        guard !Permissions.fullDiskAccessGranted, !offeredFullDiskAccess,
              !UserDefaults.standard.bool(forKey: "explorerSkipFullDiskAccess") else { return }
        offeredFullDiskAccess = true
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Give File Explorer access to all folders?"
            alert.informativeText = "Without Full Disk Access, macOS asks separately for Desktop, Documents, Downloads, iCloud Drive and other folders, and some folders stay empty.\n\nIn System Settings, turn on WinSwitch under Full Disk Access. If it is not in the list, drag WinSwitch from the Finder window into it, or click + and choose it."
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Not Now")
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Don't ask again"
            let response = alert.runModal()
            if alert.suppressionButton?.state == .on {
                UserDefaults.standard.set(true, forKey: "explorerSkipFullDiskAccess")
            }
            if response == .alertFirstButtonReturn { requestFullDiskAccess() }
        }
    }

    /// Opens the Full Disk Access pane and refreshes the open windows once access is granted.
    static func requestFullDiskAccess() {
        Permissions.requestFullDiskAccess()
        fullDiskAccessTimer?.invalidate()
        fullDiskAccessTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { timer in
            MainActor.assumeIsolated {
                guard Permissions.fullDiskAccessGranted else { return }
                timer.invalidate()
                fullDiskAccessTimer = nil
                open.forEach { $0.refresh() }
                HUD.shared.show("File Explorer can open all folders", symbol: "checkmark.shield")
            }
        }
    }

    // MARK: State

    /// The "This PC" page (the disks and user folders), kept in the history like a folder.
    static let thisPC = URL(string: "winswitch:this-pc")!
    private var isThisPC: Bool { folder == Self.thisPC }

    private var folder: URL
    private var backStack: [URL] = []
    private var forwardStack: [URL] = []
    private var items: [FileItem] = []      // everything in the folder (or search results)
    private var shown: [FileItem] = []      // after the filter and sort
    private var searchResultsFor: String?   // non-nil while showing a recursive search
    private var searchTask: Task<Void, Never>?
    private var watcher: DispatchSourceFileSystemObject?

    // MARK: Views

    private let backButton = NSButton()
    private let forwardButton = NSButton()
    private let upButton = NSButton()
    private let refreshButton = NSButton()
    private let addressField = NSTextField()
    private let searchField = NSSearchField()
    private let sidebar = NSTableView()
    private let table = ExplorerTable()
    private let status = NSTextField(labelWithString: "")
    private let tableScroll = NSScrollView()
    private let drivesScroll = NSScrollView()
    private let drivesView = DrivesView()
    private var places: [(title: String, url: URL?, symbol: String)] = []

    init(folder: URL) {
        self.folder = folder == Self.thisPC ? folder : folder.standardizedFileURL
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.minSize = NSSize(width: 560, height: 320)
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "WinSwitchExplorer"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildUI()
        load(folder, record: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Layout

    private func buildUI() {
        guard let content = window?.contentView else { return }

        func toolButton(_ button: NSButton, _ symbol: String, _ tip: String, _ action: Selector) {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            button.bezelStyle = .texturedRounded
            button.isBordered = false
            button.toolTip = tip
            button.target = self
            button.action = action
            button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        }
        toolButton(backButton, "arrow.left", "Back (Alt+Left or Backspace)", #selector(goBack))
        toolButton(forwardButton, "arrow.right", "Forward (Alt+Right)", #selector(goForward))
        toolButton(upButton, "arrow.up", "Up (Alt+Up)", #selector(goUp))
        toolButton(refreshButton, "arrow.clockwise", "Refresh (F5)", #selector(refresh))

        addressField.delegate = self
        addressField.target = self
        addressField.action = #selector(addressEntered)
        addressField.lineBreakMode = .byTruncatingHead
        addressField.placeholderString = "Type or paste a path"
        addressField.cell?.isScrollable = true

        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.widthAnchor.constraint(equalToConstant: 220).isActive = true

        let bar = NSStackView(views: [backButton, forwardButton, upButton, refreshButton, addressField, searchField])
        bar.spacing = 6
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)

        // Sidebar
        places = Self.makePlaces()
        let sideColumn = NSTableColumn(identifier: .init("place"))
        sidebar.addTableColumn(sideColumn)
        sidebar.headerView = nil
        sidebar.style = .sourceList
        sidebar.rowHeight = 26
        sidebar.dataSource = self
        sidebar.delegate = self
        sidebar.target = self
        sidebar.action = #selector(sidebarClicked)
        let sideScroll = NSScrollView()
        sideScroll.documentView = sidebar
        sideScroll.hasVerticalScroller = true
        sideScroll.drawsBackground = false

        // Details list
        for (id, title, width) in [("name", "Name", 340.0), ("date", "Date modified", 150.0), ("type", "Type", 150.0), ("size", "Size", 90.0)] {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title
            column.width = width
            column.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true)
            column.minWidth = id == "name" ? 160 : 60
            if id == "size" { column.headerCell.alignment = .right }
            table.addTableColumn(column)
        }
        table.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        table.style = .fullWidth
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle // Name takes the spare width
        table.usesAlternatingRowBackgroundColors = false
        table.allowsMultipleSelection = true
        table.rowHeight = 22
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelected)
        table.explorer = self
        table.registerForDraggedTypes([.fileURL])
        // Offer every kind of drag like Finder: apps such as video editors take files as a link or generic drop, and
        // refuse a drag that only offers copy and move.
        table.setDraggingSourceOperationMask(.every, forLocal: false)
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        tableScroll.documentView = table
        tableScroll.hasVerticalScroller = true
        tableScroll.hasHorizontalScroller = false

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        drivesView.translatesAutoresizingMaskIntoConstraints = false
        drivesScroll.documentView = drivesView
        drivesScroll.hasVerticalScroller = true
        drivesScroll.drawsBackground = true
        drivesScroll.backgroundColor = .textBackgroundColor
        drivesView.widthAnchor.constraint(equalTo: drivesScroll.contentView.widthAnchor).isActive = true
        drivesView.topAnchor.constraint(equalTo: drivesScroll.contentView.topAnchor).isActive = true
        drivesView.onOpen = { [weak self] url in self?.load(url) }
        drivesView.onProperties = { url in PropertiesWindow.show([url]) }
        let listArea = NSView()
        for view in [tableScroll, drivesScroll] {
            view.translatesAutoresizingMaskIntoConstraints = false
            listArea.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: listArea.leadingAnchor), view.trailingAnchor.constraint(equalTo: listArea.trailingAnchor),
                view.topAnchor.constraint(equalTo: listArea.topAnchor), view.bottomAnchor.constraint(equalTo: listArea.bottomAnchor),
            ])
        }
        drivesScroll.isHidden = true
        split.addArrangedSubview(sideScroll)
        split.addArrangedSubview(listArea)
        sideScroll.widthAnchor.constraint(equalToConstant: 190).isActive = true

        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        let statusBar = NSStackView(views: [status])
        statusBar.edgeInsets = NSEdgeInsets(top: 4, left: 12, bottom: 5, right: 12)

        let stack = NSStackView(views: [bar, split, statusBar])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            bar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            split.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusBar.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
    }

    private static func makePlaces() -> [(title: String, url: URL?, symbol: String)] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var list: [(String, URL?, String)] = [
            ("Quick access", nil, ""),
            ("Home", home, "house"),
            ("Desktop", home.appendingPathComponent("Desktop"), "menubar.dock.rectangle"),
            ("Documents", home.appendingPathComponent("Documents"), "doc"),
            ("Downloads", home.appendingPathComponent("Downloads"), "arrow.down.circle"),
            ("GitHub", home.appendingPathComponent("Documents/GitHub"), "chevron.left.forwardslash.chevron.right"),
            ("Pictures", home.appendingPathComponent("Pictures"), "photo"),
            ("Applications", URL(fileURLWithPath: "/Applications"), "square.grid.2x2"),
            ("This PC", Explorer.thisPC, "desktopcomputer"),
        ]
        list = list.filter { $0.1 == nil || $0.1 == Explorer.thisPC || fm.fileExists(atPath: $0.1!.path) }
        let volumes = fm.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeLocalizedNameKey], options: [.skipHiddenVolumes]) ?? []
        for volume in volumes {
            let name = (try? volume.resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName) ?? nil
            list.append((name ?? volume.lastPathComponent, volume, volume.path == "/" ? "internaldrive" : "externaldrive"))
        }
        return list
    }

    // MARK: Navigation

    func load(_ url: URL, record: Bool = true, select: [URL] = []) {
        let url = url == Self.thisPC ? url : url.standardizedFileURL
        if record && url != folder {
            backStack.append(folder)
            forwardStack.removeAll()
        }
        folder = url
        searchTask?.cancel()
        searchResultsFor = nil
        searchField.stringValue = ""
        backButton.isEnabled = !backStack.isEmpty
        forwardButton.isEnabled = !forwardStack.isEmpty
        tableScroll.isHidden = isThisPC
        drivesScroll.isHidden = !isThisPC
        searchField.isEnabled = !isThisPC
        if isThisPC {
            watcher?.cancel()
            drivesView.reload()
            window?.title = "This PC"
            window?.representedURL = nil
            addressField.stringValue = "This PC"
            upButton.isEnabled = false
            status.stringValue = "\(drivesView.drives.count) drive\(drivesView.drives.count == 1 ? "" : "s")"
            if let row = places.firstIndex(where: { $0.url == Self.thisPC }) { sidebar.selectRowIndexes([row], byExtendingSelection: false) }
            window?.makeFirstResponder(drivesView)
            return
        }
        items = FileItem.contents(of: url, showHidden: Self.showHidden)
        applyFilterAndSort()
        watch(url)

        window?.title = url.path == "/" ? "Macintosh HD" : FileManager.default.displayName(atPath: url.path)
        window?.representedURL = url
        addressField.stringValue = (url.path as NSString).abbreviatingWithTildeInPath
        upButton.isEnabled = true
        if let row = places.firstIndex(where: { $0.url?.standardizedFileURL == url }) {
            sidebar.selectRowIndexes([row], byExtendingSelection: false)
        } else {
            sidebar.deselectAll(nil)
        }
        if !select.isEmpty { self.select(select) } else if !shown.isEmpty { table.scrollRowToVisible(0) }
        window?.makeFirstResponder(table)
    }

    @objc func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(folder)
        load(previous, record: false, select: [folder])
    }

    @objc func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(folder)
        load(next, record: false)
    }

    /// Up from the top of a disk goes to This PC, like Windows.
    @objc func goUp() {
        guard !isThisPC else { return }
        if folder.path == "/" || DriveInfo.isMountPoint(folder) { load(Self.thisPC); return }
        load(folder.deletingLastPathComponent(), select: [folder])
    }

    @objc func refresh() {
        if isThisPC { drivesView.reload(); return }
        let selected = selectedURLs()
        if let query = searchResultsFor {
            runSearch(query)
        } else {
            items = FileItem.contents(of: folder, showHidden: Self.showHidden)
            applyFilterAndSort()
            select(selected)
        }
    }

    @objc private func sidebarClicked() {
        let row = sidebar.clickedRow >= 0 ? sidebar.clickedRow : sidebar.selectedRow
        guard places.indices.contains(row), let url = places[row].url else { return }
        load(url)
    }

    /// Address bar: a folder opens here, a file opens in its app, a missing path shows an error.
    @objc private func addressEntered() {
        let typed = addressField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        if ["this pc", "my computer", "computer", "this mac"].contains(typed) { load(Self.thisPC); return }
        let path = RunCommand.expand(addressField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
            showError("Can't find '\(addressField.stringValue)'. Check the spelling and try again.")
            addressField.stringValue = isThisPC ? "This PC" : (folder.path as NSString).abbreviatingWithTildeInPath
            return
        }
        let url = URL(fileURLWithPath: path)
        if isDir.boolValue && !(NSWorkspace.shared.isFilePackage(atPath: path)) {
            load(url)
        } else {
            load(url.deletingLastPathComponent(), select: [url])
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Watching for changes

    private func watch(_ url: URL) {
        watcher?.cancel()
        let fd = Darwin.open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.searchResultsFor == nil, self.table.editedRow < 0 else { return }
                self.refresh()
            }
        }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        watcher = source
    }

    // MARK: Search

    /// Typing filters this folder; Enter searches all subfolders.
    @objc private func searchChanged() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        let pressedEnter = NSApp.currentEvent?.type == .keyDown && NSApp.currentEvent?.keyCode == 36
        if query.isEmpty {
            if searchResultsFor != nil { load(folder, record: false) } else { applyFilterAndSort() }
        } else if pressedEnter {
            runSearch(query)
        } else if searchResultsFor == nil {
            applyFilterAndSort()
        }
    }

    private func runSearch(_ query: String) {
        searchTask?.cancel()
        searchResultsFor = query
        items = []
        applyFilterAndSort()
        status.stringValue = "Searching \(folder.lastPathComponent) and subfolders for \"\(query)\"…"
        let root = folder, showHidden = Self.showHidden
        searchTask = Task.detached(priority: .userInitiated) {
            var found: [FileItem] = []
            let options: FileManager.DirectoryEnumerationOptions = showHidden ? [.skipsPackageDescendants] : [.skipsHiddenFiles, .skipsPackageDescendants]
            let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: FileItem.resourceKeys, options: options)
            while let url = enumerator?.nextObject() as? URL {
                if Task.isCancelled { return }
                if url.lastPathComponent.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil,
                   let item = FileItem(url: url) {
                    found.append(item)
                    if found.count >= 5000 { break }
                }
            }
            let results = found
            await MainActor.run { [weak self] in
                guard let self, self.searchResultsFor == query else { return }
                self.items = results
                self.applyFilterAndSort()
            }
        }
    }

    private func applyFilterAndSort() {
        var list = items
        if searchResultsFor == nil {
            let query = searchField.stringValue.trimmingCharacters(in: .whitespaces)
            if !query.isEmpty {
                list = list.filter { $0.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            }
        }
        let descriptor = table.sortDescriptors.first ?? NSSortDescriptor(key: "name", ascending: true)
        let ascending = descriptor.ascending
        list.sort { a, b in
            // Folders always first, like Windows.
            if a.opensAsFolder != b.opensAsFolder { return a.opensAsFolder }
            let order: ComparisonResult
            switch descriptor.key {
            case "date": order = (a.modified ?? .distantPast).compare(b.modified ?? .distantPast)
            case "type": order = a.typeDescription.localizedStandardCompare(b.typeDescription)
            case "size": order = (a.size ?? -1) == (b.size ?? -1) ? .orderedSame : ((a.size ?? -1) < (b.size ?? -1) ? .orderedAscending : .orderedDescending)
            default: order = .orderedSame
            }
            if order != .orderedSame { return ascending ? order == .orderedAscending : order == .orderedDescending }
            let byName = a.name.localizedStandardCompare(b.name)
            return descriptor.key == "name" && !ascending ? byName == .orderedDescending : byName == .orderedAscending
        }
        shown = list
        table.reloadData()
        updateStatus()
    }

    private func updateStatus() {
        let count = shown.count
        var text = searchResultsFor.map { "\(count) result\(count == 1 ? "" : "s") for \"\($0)\"" } ?? "\(count) item\(count == 1 ? "" : "s")"
        let selected = table.selectedRowIndexes.compactMap { shown.indices.contains($0) ? shown[$0] : nil }
        if !selected.isEmpty {
            text += "     \(selected.count) item\(selected.count == 1 ? "" : "s") selected"
            let bytes = selected.compactMap(\.size).reduce(0, +)
            if bytes > 0 { text += "  " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
        }
        status.stringValue = text
    }

    // MARK: Selection and opening

    func selectedURLs() -> [URL] {
        table.selectedRowIndexes.compactMap { shown.indices.contains($0) ? shown[$0].url : nil }
    }

    func select(_ urls: [URL]) {
        let wanted = Set(urls.map(\.standardizedFileURL))
        let rows = IndexSet(shown.indices.filter { wanted.contains(shown[$0].url.standardizedFileURL) })
        table.selectRowIndexes(rows, byExtendingSelection: false)
        if let first = rows.first { table.scrollRowToVisible(first) }
    }

    /// Double-click or Enter: folders open here, files in their default app.
    @objc func openSelected() {
        let rows = table.clickedRow >= 0 && NSApp.currentEvent?.type == .leftMouseUp ? IndexSet(integer: table.clickedRow) : table.selectedRowIndexes
        let chosen = rows.compactMap { shown.indices.contains($0) ? shown[$0] : nil }
        if chosen.count == 1, chosen[0].opensAsFolder {
            load(chosen[0].url)
            return
        }
        for item in chosen {
            if item.opensAsFolder {
                Explorer.openWindow(at: item.url, asTabOf: window)
            } else {
                NSWorkspace.shared.open(item.url)
            }
        }
    }

    // MARK: Clipboard and file operations (Edit menu / Ctrl+C, X, V)

    @objc func copy(_ sender: Any?) {
        let urls = selectedURLs()
        guard !urls.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
        Self.cut = nil
    }

    @objc func cut(_ sender: Any?) {
        copy(sender)
        let urls = selectedURLs()
        guard !urls.isEmpty else { return }
        Self.cut = (urls, NSPasteboard.general.changeCount)
    }

    @objc func paste(_ sender: Any?) {
        guard !isThisPC else { return }
        let pb = NSPasteboard.general
        guard let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return }
        let move = Self.cut.map { $0.changeCount == pb.changeCount } ?? false
        let target = folder
        FileCopy.run(urls, to: target, move: move, window: window) { [weak self] copied, error in
            guard let self else { return }
            if move { Self.cut = nil; pb.clearContents() }
            self.refresh()
            if self.folder == target { self.select(copied) }
            if let error { self.showError(error.localizedDescription) }
        }
    }

    @objc func copyPath(_ sender: Any?) {
        let paths = selectedURLs().map(\.path)
        let text = paths.isEmpty ? folder.path : paths.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Delete key: move to the Trash (Recycle Bin).
    @objc func deleteSelected(_ sender: Any?) {
        let urls = selectedURLs()
        guard !urls.isEmpty else { return }
        let row = table.selectedRowIndexes.first ?? 0
        NSWorkspace.shared.recycle(urls) { [weak self] _, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let error { self.showError(error.localizedDescription) }
                self.refresh()
                let next = min(row, self.shown.count - 1)
                if next >= 0 { self.table.selectRowIndexes([next], byExtendingSelection: false) }
            }
        }
    }

    @objc func newFolder(_ sender: Any?) {
        guard !isThisPC else { return }
        let url = FileOps.uniqueURL(for: "New folder", in: folder, copySuffix: false)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        } catch {
            showError(error.localizedDescription)
            return
        }
        refresh()
        select([url])
        renameSelected(nil)
    }

    /// F2: edit the name in place.
    @objc func renameSelected(_ sender: Any?) {
        guard table.selectedRowIndexes.count == 1, let row = table.selectedRowIndexes.first else { return }
        table.editColumn(0, row: row, with: nil, select: true)
        // Select the name without the extension, like Windows.
        if let editor = table.currentEditor(), shown.indices.contains(row) {
            let name = shown[row].name as NSString
            let length = shown[row].isDirectory ? name.length : (name.deletingPathExtension as NSString).length
            editor.selectedRange = NSRange(location: 0, length: length)
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field !== addressField, field !== searchField else { return }
        let row = table.row(for: field)
        guard shown.indices.contains(row) else { return }
        let item = shown[row]
        let newName = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !newName.isEmpty, newName != item.name, !newName.contains("/") else {
            field.stringValue = item.name
            return
        }
        let target = item.url.deletingLastPathComponent().appendingPathComponent(newName)
        do {
            try FileManager.default.moveItem(at: item.url, to: target)
            refresh()
            select([target])
        } catch {
            field.stringValue = item.name
            showError(error.localizedDescription)
        }
        window?.makeFirstResponder(table)
    }

    @objc func toggleHidden(_ sender: Any?) {
        Self.showHidden.toggle()
        refresh()
    }

    @objc func focusAddress(_ sender: Any?) {
        addressField.stringValue = folder.path
        window?.makeFirstResponder(addressField)
        addressField.currentEditor()?.selectAll(nil)
    }

    @objc func focusSearch(_ sender: Any?) { window?.makeFirstResponder(searchField) }

    @objc func openTerminalHere(_ sender: Any?) {
        let target = selectedURLs().first.flatMap { RunCommand.isDirectory($0.path) ? $0 : nil } ?? folder
        if let error = RunCommand.openTerminal(cd: target.path, command: nil) { showError(error) }
    }

    @objc func showInFinder(_ sender: Any?) {
        let urls = selectedURLs()
        if urls.isEmpty { NSWorkspace.shared.open(folder) } else { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    @objc private func openWith(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(selectedURLs(), withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Cmd+T (Ctrl+T on the Windows keyboard): new tab in this folder.
    @objc override func newWindowForTab(_ sender: Any?) {
        Explorer.openWindow(at: folder, asTabOf: window)
    }

    @objc func newExplorerWindow(_ sender: Any?) {
        Explorer.openWindow(at: folder)
    }

    private func showError(_ text: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = text
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window)
    }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let clicked = table.clickedRow
        if clicked >= 0 && !table.selectedRowIndexes.contains(clicked) {
            table.selectRowIndexes([clicked], byExtendingSelection: false)
        }
        let selected = selectedURLs()

        func add(_ title: String, _ action: Selector, _ key: String = "", _ mods: NSEvent.ModifierFlags = []) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            item.target = self
            menu.addItem(item)
        }

        if !selected.isEmpty {
            add("Open", #selector(openSelected))
            if let first = selected.first, !RunCommand.isDirectory(first.path) {
                let openWith = NSMenuItem(title: "Open with", action: nil, keyEquivalent: "")
                let sub = NSMenu()
                let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: first)
                for app in NSWorkspace.shared.urlsForApplications(toOpen: first).prefix(15) {
                    var name = FileManager.default.displayName(atPath: app.path)
                    if app == defaultApp { name += " (default)" }
                    let item = NSMenuItem(title: name, action: #selector(openWith(_:)), keyEquivalent: "")
                    item.representedObject = app
                    item.target = self
                    let icon = NSWorkspace.shared.icon(forFile: app.path)
                    icon.size = NSSize(width: 16, height: 16)
                    item.image = icon
                    sub.addItem(item)
                }
                openWith.submenu = sub
                menu.addItem(openWith)
            }
            add("Share", #selector(share(_:)))
            menu.addItem(.separator())
            add("Cut", #selector(cut(_:)), "x", .command)
            add("Copy", #selector(copy(_:)), "c", .command)
        }
        add("Paste", #selector(paste(_:)), "v", .command)
        menu.addItem(.separator())
        add(selected.isEmpty ? "Copy folder path" : "Copy as path", #selector(copyPath(_:)), "c", [.command, .option])
        add("Open in Terminal", #selector(openTerminalHere(_:)))
        add("Show in Finder", #selector(showInFinder(_:)))
        menu.addItem(.separator())
        if selected.count == 1 { add("Rename", #selector(renameSelected(_:))) }
        if !selected.isEmpty { add("Delete", #selector(deleteSelected(_:))) }
        add("New folder", #selector(newFolder(_:)), "n", [.command, .shift])
        add(Self.showHidden ? "Hide hidden files" : "Show hidden files", #selector(toggleHidden(_:)))
        add("Refresh", #selector(refresh))
        menu.addItem(.separator())
        add("Properties", #selector(showProperties(_:)), "\r", .option)
    }

    /// Share: the macOS share sheet (AirDrop, Mail, Messages...) next to the selected row, like Windows' Share dialog.
    @objc func share(_ sender: Any?) {
        let urls = selectedURLs()
        guard !urls.isEmpty else { return }
        let row = table.selectedRowIndexes.first ?? 0
        let rect = row < table.numberOfRows ? table.rect(ofRow: row) : table.visibleRect
        let anchor = NSRect(x: rect.minX + 40, y: rect.minY, width: 160, height: rect.height).intersection(table.visibleRect)
        NSSharingServicePicker(items: urls).show(relativeTo: anchor.isEmpty ? table.visibleRect : anchor, of: table, preferredEdge: .maxY)
    }

    /// Alt+Enter: Properties of the selection, or of the folder itself when nothing is selected.
    @objc func showProperties(_ sender: Any?) {
        if isThisPC {
            if let selected = drivesView.selected { PropertiesWindow.show([selected]) }
            return
        }
        let urls = selectedURLs()
        PropertiesWindow.show(urls.isEmpty ? [folder] : urls) { [weak self] in self?.refresh() }
    }

    // MARK: Table data

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === sidebar ? places.count : shown.count
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        tableView === sidebar && places[row].url == nil
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        tableView !== sidebar || places[row].url != nil
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === sidebar {
            let place = places[row]
            if place.url == nil {
                let label = NSTextField(labelWithString: place.title)
                label.font = .systemFont(ofSize: 11, weight: .semibold)
                label.textColor = .secondaryLabelColor
                return label
            }
            return Self.cell(text: place.title, image: NSImage(systemSymbolName: place.symbol, accessibilityDescription: nil), editable: false)
        }

        let item = shown[row]
        switch tableColumn?.identifier.rawValue {
        case "name":
            let icon = NSWorkspace.shared.icon(forFile: item.url.path)
            icon.size = NSSize(width: 16, height: 16)
            let cell = Self.cell(text: item.name, image: icon, editable: true)
            cell.textField?.delegate = self
            cell.toolTip = searchResultsFor != nil ? item.url.path : nil
            if item.isHidden { cell.alphaValue = 0.6 }
            return cell
        case "date": return Self.cell(text: item.dateText, color: .secondaryLabelColor)
        case "type": return Self.cell(text: item.typeDescription, color: .secondaryLabelColor)
        case "size":
            let cell = Self.cell(text: item.sizeText, color: .secondaryLabelColor)
            cell.textField?.alignment = .right
            return cell
        default: return nil
        }
    }

    private static func cell(text: String, image: NSImage? = nil, editable: Bool = false, color: NSColor = .labelColor) -> NSTableCellView {
        let cell = NSTableCellView()
        let field = NSTextField(labelWithString: text)
        field.lineBreakMode = .byTruncatingMiddle
        field.textColor = color
        field.isEditable = editable
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(field)
        cell.textField = field
        var leading = cell.leadingAnchor
        if let image {
            let imageView = NSImageView(image: image)
            imageView.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(imageView)
            cell.imageView = imageView
            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 16),
                imageView.heightAnchor.constraint(equalToConstant: 16),
            ])
            leading = imageView.trailingAnchor
        }
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leading, constant: 6),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard tableView === table else { return }
        let selected = selectedURLs()
        applyFilterAndSort()
        select(selected)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if (notification.object as? NSTableView) === table { updateStatus() }
    }

    // MARK: Drag and drop

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        tableView === table ? shown[row].url as NSURL : nil
    }

    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        guard tableView === table else { return [] }
        // Dropping on a folder row goes into that folder; anywhere else goes into the current folder.
        if op == .on, shown.indices.contains(row), shown[row].opensAsFolder {
            return dragOperation(info, into: shown[row].url)
        }
        tableView.setDropRow(-1, dropOperation: .on)
        return dragOperation(info, into: folder)
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        let destination = row >= 0 && shown.indices.contains(row) && shown[row].opensAsFolder ? shown[row].url : folder
        guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] else { return false }
        let move = dragOperation(info, into: destination) == .move
        FileCopy.run(urls, to: destination, move: move, window: window) { [weak self] copied, error in
            guard let self else { return }
            self.refresh()
            if destination == self.folder { self.select(copied) }
            if let error { self.showError(error.localizedDescription) }
        }
        return true
    }

    /// Like Windows: move on the same drive, copy to another drive; Alt forces a copy.
    private func dragOperation(_ info: any NSDraggingInfo, into destination: URL) -> NSDragOperation {
        guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              let first = urls.first else { return [] }
        if urls.contains(where: { $0.standardizedFileURL == destination.standardizedFileURL }) { return [] }
        if NSEvent.modifierFlags.contains(.option) || urls.contains(where: FileCopy.isAppStorage) { return .copy }
        return FileOps.sameVolume(first, destination) ? .move : .copy
    }

    // MARK: Window

    func windowWillClose(_ notification: Notification) {
        watcher?.cancel()
        searchTask?.cancel()
        Self.open.removeAll { $0 === self }
        if Self.open.isEmpty && !TaskManager.isOpen {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let alt = flags.contains(.option), cmd = flags.contains(.command)
        switch Int(event.keyCode) {
        case 36 where alt, 76 where alt:              // Alt+Enter: Properties
            showProperties(nil); return true
        case 36 where !cmd, 76 where !cmd:            // Enter
            openSelected(); return true
        case 51 where flags.isEmpty:                  // Backspace: back
            goBack(); return true
        case 117:                                     // Delete: to Trash
            deleteSelected(nil); return true
        case 120:                                     // F2
            renameSelected(nil); return true
        case 96:                                      // F5
            refresh(); return true
        case 126 where alt:                           // Alt+Up
            goUp(); return true
        case 123 where alt:                           // Alt+Left
            goBack(); return true
        case 124 where alt:                           // Alt+Right
            goForward(); return true
        default:
            return false
        }
    }
}

/// The details list: forwards Windows keys to the Explorer and keeps Edit menu commands working.
final class ExplorerTable: NSTableView {
    weak var explorer: Explorer?
    private var lastToggle: TimeInterval = -1

    /// Ctrl+click adds or removes one item from the selection, like Windows (macOS would open the context menu).
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { toggleRow(event); return }
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        if event.type == .leftMouseDown && event.modifierFlags.contains(.control) {
            toggleRow(event)
            return nil
        }
        return super.menu(for: event)
    }

    private func toggleRow(_ event: NSEvent) {
        // AppKit can deliver the same Ctrl+click both as a click and as a menu request; toggle once.
        guard event.timestamp != lastToggle else { return }
        lastToggle = event.timestamp
        window?.makeFirstResponder(self)
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return }
        var rows = selectedRowIndexes
        if rows.contains(row) { rows.remove(row) } else { rows.insert(row) }
        selectRowIndexes(rows, byExtendingSelection: false)
    }

    override func keyDown(with event: NSEvent) {
        if MainActor.assumeIsolated({ explorer?.handleKey(event) }) == true { return }
        super.keyDown(with: event)
    }

    @objc func copy(_ sender: Any?) { MainActor.assumeIsolated { explorer?.copy(sender) } }
    @objc func cut(_ sender: Any?) { MainActor.assumeIsolated { explorer?.cut(sender) } }
    @objc func paste(_ sender: Any?) { MainActor.assumeIsolated { explorer?.paste(sender) } }
    @objc func delete(_ sender: Any?) { MainActor.assumeIsolated { explorer?.deleteSelected(sender) } }
}
