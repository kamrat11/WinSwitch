import AppKit
import UniformTypeIdentifiers

/// The Windows "Save As" dialog: navigation pane, back / forward / up, an address bar you can type in, a file list,
/// and a "File name" box that takes a name, a relative path or a full path (~/notes/todo.txt, /tmp/a.txt, or with
/// backslashes). Used by Notepad, Notepad++ and MS Paint instead of the macOS save panel.
@MainActor
public final class SaveDialog: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSWindowDelegate {
    public struct FileType {
        public let name: String
        /// Without dots; empty means all files.
        public let extensions: [String]
        public init(_ name: String, _ extensions: [String]) {
            self.name = name
            self.extensions = extensions
        }
        var title: String {
            extensions.isEmpty ? "\(name) (*.*)" : "\(name) (\(extensions.map { "*.\($0)" }.joined(separator: ";")))"
        }
    }

    public struct Result {
        public let url: URL
        public let typeIndex: Int
        public let extraIndex: Int
    }

    public var title = "Save As"
    public var fileName = ""
    public var directory: URL?
    public var types: [FileType] = [FileType("All Files", [])]
    public var typeIndex = 0
    /// An extra popup next to the Save button, like Notepad's Encoding.
    public var extra: (label: String, items: [String], selected: Int)?
    /// UserDefaults key for the folder of the last save.
    public var rememberKey = "saveDialogFolder"

    private var folder = FileManager.default.homeDirectoryForCurrentUser
    private var back: [URL] = []
    private var forward: [URL] = []
    private var items: [(url: URL, isFolder: Bool, date: Date?, type: String, size: Int?)] = []
    private var shown: [(url: URL, isFolder: Bool, date: Date?, type: String, size: Int?)] = []
    private var places: [(String, URL?, String)] = []
    private var result: Result?

    private var panel: NSPanel!
    private let backButton = NSButton()
    private let forwardButton = NSButton()
    private let upButton = NSButton()
    private let address = NSTextField()
    private let search = NSSearchField()
    private let sidebar = NSTableView()
    private let table = NSTableView()
    private let nameField = NSComboBox()
    private let typePopup = NSPopUpButton()
    private let extraPopup = NSPopUpButton()

    public override init() { super.init() }

    /// Shows the dialog modally; nil when cancelled.
    public func run() -> Result? {
        let remembered = UserDefaults.standard.string(forKey: rememberKey).map { URL(fileURLWithPath: $0) }
        let start = directory ?? remembered ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        build()
        navigate(to: isFolder(start) ? start : FileManager.default.homeDirectoryForCurrentUser, record: false)
        nameField.stringValue = fileName
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(nameField)
        // Select the name without its extension, like Windows.
        if let editor = nameField.currentEditor() {
            let stem = (fileName as NSString).deletingPathExtension
            editor.selectedRange = NSRange(location: 0, length: (stem as NSString).length)
        }
        NSApp.runModal(for: panel)
        panel.orderOut(nil)
        return result
    }

    // MARK: Layout

    private func build() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 860, height: 540), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = title
        panel.minSize = NSSize(width: 620, height: 380)
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        guard let content = panel.contentView else { return }

        for (button, symbol, tip, action) in [(backButton, "arrow.left", "Back", #selector(goBack)), (forwardButton, "arrow.right", "Forward", #selector(goForward)),
                                              (upButton, "arrow.up", "Up to the parent folder", #selector(goUp))] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            button.bezelStyle = .texturedRounded
            button.isBordered = false
            button.toolTip = tip
            button.target = self
            button.action = action
            button.widthAnchor.constraint(equalToConstant: 26).isActive = true
        }
        address.delegate = self
        address.target = self
        address.action = #selector(addressEntered)
        address.lineBreakMode = .byTruncatingHead
        address.cell?.isScrollable = true
        search.placeholderString = "Search"
        search.target = self
        search.action = #selector(filter)
        search.widthAnchor.constraint(equalToConstant: 200).isActive = true
        let newFolder = NSButton(title: "New folder", target: self, action: #selector(makeFolder))
        newFolder.bezelStyle = .rounded
        let top = NSStackView(views: [backButton, forwardButton, upButton, address, search])
        top.spacing = 6
        let commands = NSStackView(views: [newFolder, NSView()])

        // Navigation pane.
        places = navigationPlaces()
        let sideColumn = NSTableColumn(identifier: .init("place"))
        sidebar.addTableColumn(sideColumn)
        sidebar.headerView = nil
        sidebar.style = .sourceList
        sidebar.rowHeight = 24
        sidebar.dataSource = self
        sidebar.delegate = self
        let sideScroll = NSScrollView()
        sideScroll.documentView = sidebar
        sideScroll.hasVerticalScroller = true
        sideScroll.widthAnchor.constraint(equalToConstant: 180).isActive = true

        // File list.
        for (id, title, width) in [("name", "Name", 260.0), ("date", "Date modified", 140.0), ("type", "Type", 130.0), ("size", "Size", 80.0)] {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title
            column.width = width
            column.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true)
            table.addTableColumn(column)
        }
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.rowHeight = 20
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openRow)
        table.allowsMultipleSelection = false
        let tableScroll = NSScrollView()
        tableScroll.documentView = table
        tableScroll.hasVerticalScroller = true
        tableScroll.borderType = .bezelBorder

        let middle = NSSplitView()
        middle.isVertical = true
        middle.dividerStyle = .thin
        middle.addArrangedSubview(sideScroll)
        middle.addArrangedSubview(tableScroll)
        middle.setHoldingPriority(.defaultHigh, forSubviewAt: 0)

        // File name, type and the buttons.
        nameField.completes = false
        nameField.addItems(withObjectValues: UserDefaults.standard.stringArray(forKey: rememberKey + ".names") ?? [])
        typePopup.addItems(withTitles: types.map(\.title))
        typePopup.selectItem(at: min(typeIndex, types.count - 1))
        typePopup.target = self
        typePopup.action = #selector(typeChanged)
        let save = NSButton(title: "Save", target: self, action: #selector(saveClicked))
        save.keyEquivalent = "\r"
        save.bezelStyle = .rounded
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancel.keyEquivalent = "\u{1b}"
        cancel.bezelStyle = .rounded
        for b in [save, cancel] { b.widthAnchor.constraint(equalToConstant: 90).isActive = true }
        var buttonRow: [NSView] = [NSView()]
        if let extra {
            extraPopup.addItems(withTitles: extra.items)
            extraPopup.selectItem(at: extra.selected)
            buttonRow += [NSTextField(labelWithString: extra.label + ":"), extraPopup]
        }
        buttonRow += [save, cancel]
        let buttons = NSStackView(views: buttonRow)
        let grid = NSGridView(views: [
            [label("File name:"), nameField],
            [label("Save as type:"), typePopup],
        ])
        grid.rowSpacing = 8
        grid.column(at: 0).xPlacement = .trailing

        let stack = NSStackView(views: [top, commands, middle, grid, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            top.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            commands.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            middle.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            grid.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            nameField.widthAnchor.constraint(greaterThanOrEqualToConstant: 400),
        ])
        grid.column(at: 1).width = 600
        middle.setContentHuggingPriority(.init(1), for: .vertical)
        let width = content.widthAnchor.constraint(equalToConstant: 860)
        let height = content.heightAnchor.constraint(equalToConstant: 540)
        width.priority = .defaultLow
        height.priority = .defaultLow
        NSLayoutConstraint.activate([width, height, middle.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
                                     content.widthAnchor.constraint(greaterThanOrEqualToConstant: 620)])
        panel.layoutIfNeeded()
        panel.setContentSize(NSSize(width: 860, height: 540))
    }

    private func label(_ text: String) -> NSTextField { NSTextField(labelWithString: text) }

    private func navigationPlaces() -> [(String, URL?, String)] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        func dir(_ d: FileManager.SearchPathDirectory) -> URL? { fm.urls(for: d, in: .userDomainMask).first }
        var list: [(String, URL?, String)] = [
            ("Quick access", nil, ""),
            ("Home", home, "house"), ("Desktop", dir(.desktopDirectory), "menubar.dock.rectangle"),
            ("Documents", dir(.documentDirectory), "doc"), ("Downloads", dir(.downloadsDirectory), "arrow.down.circle"),
            ("Pictures", dir(.picturesDirectory), "photo"), ("Music", dir(.musicDirectory), "music.note"),
            ("Videos", dir(.moviesDirectory), "film"),
        ]
        let iCloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        if fm.fileExists(atPath: iCloud.path) { list.append(("iCloud Drive", iCloud, "icloud")) }
        list.append(("This Mac", nil, ""))
        for volume in fm.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeLocalizedNameKey], options: [.skipHiddenVolumes]) ?? [] {
            let name = (try? volume.resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName) ?? volume.lastPathComponent
            list.append((name ?? "Disk", volume, volume.path == "/" ? "internaldrive" : "externaldrive"))
        }
        return list
    }

    // MARK: Navigation

    private func isFolder(_ url: URL) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &dir) && dir.boolValue
            && !NSWorkspace.shared.isFilePackage(atPath: url.path)
    }

    private func navigate(to url: URL, record: Bool = true) {
        let url = url.standardizedFileURL
        if record && url != folder {
            back.append(folder)
            forward.removeAll()
        }
        folder = url
        address.stringValue = (url.path as NSString).abbreviatingWithTildeInPath
        backButton.isEnabled = !back.isEmpty
        forwardButton.isEnabled = !forward.isEmpty
        upButton.isEnabled = url.path != "/"
        search.stringValue = ""
        load()
        if let row = places.firstIndex(where: { $0.1?.standardizedFileURL == url }) {
            sidebar.selectRowIndexes([row], byExtendingSelection: false)
        } else {
            sidebar.deselectAll(nil)
        }
    }

    private func load() {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .contentModificationDateKey, .localizedTypeDescriptionKey, .fileSizeKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        items = urls.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            let folder = v.isDirectory == true && v.isPackage != true
            return (url, folder, v.contentModificationDate, v.localizedTypeDescription ?? (folder ? "Folder" : "File"), folder ? nil : v.fileSize)
        }
        filter()
    }

    /// Folders, then the files of the chosen type (all files for "All Files"), matching the search text.
    @objc private func filter() {
        let type = types[max(0, typePopup.indexOfSelectedItem)]
        let query = search.stringValue.lowercased()
        shown = items.filter { item in
            if !query.isEmpty && !item.url.lastPathComponent.lowercased().contains(query) { return false }
            return item.isFolder || type.extensions.isEmpty || type.extensions.contains(item.url.pathExtension.lowercased())
        }
        sort()
    }

    private func sort() {
        let descriptor = table.sortDescriptors.first
        let key = descriptor?.key ?? "name"
        let ascending = descriptor?.ascending ?? true
        shown.sort { a, b in
            if a.isFolder != b.isFolder { return a.isFolder }
            let order: Bool
            switch key {
            case "date": order = (a.date ?? .distantPast) < (b.date ?? .distantPast)
            case "type": order = a.type.localizedStandardCompare(b.type) == .orderedAscending
            case "size": order = (a.size ?? 0) < (b.size ?? 0)
            default: order = a.url.lastPathComponent.localizedStandardCompare(b.url.lastPathComponent) == .orderedAscending
            }
            return ascending ? order : !order
        }
        table.reloadData()
    }

    @objc private func goBack() {
        guard let previous = back.popLast() else { return }
        forward.append(folder)
        navigate(to: previous, record: false)
    }

    @objc private func goForward() {
        guard let next = forward.popLast() else { return }
        back.append(folder)
        navigate(to: next, record: false)
    }

    @objc private func goUp() { navigate(to: folder.deletingLastPathComponent()) }

    @objc private func addressEntered() {
        let url = resolve(address.stringValue)
        if isFolder(url) {
            navigate(to: url)
            panel.makeFirstResponder(nameField)
        } else {
            alert("Can't find '\(address.stringValue)'. Check the spelling and try again.")
            address.stringValue = (folder.path as NSString).abbreviatingWithTildeInPath
        }
    }

    @objc private func openRow() {
        let row = table.clickedRow
        guard shown.indices.contains(row) else { return }
        if shown[row].isFolder { navigate(to: shown[row].url) } else { saveClicked() }
    }

    @objc private func makeFolder() {
        var url = folder.appendingPathComponent("New folder")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("New folder (\(n))")
            n += 1
        }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            load()
            if let row = shown.firstIndex(where: { $0.url == url }) {
                table.selectRowIndexes([row], byExtendingSelection: false)
                table.scrollRowToVisible(row)
            }
        } catch {
            alert(error.localizedDescription)
        }
    }

    @objc private func typeChanged() {
        // Like Windows: switching the type changes the extension in the name box.
        let type = types[typePopup.indexOfSelectedItem]
        let name = nameField.stringValue
        if let ext = type.extensions.first, !name.isEmpty {
            nameField.stringValue = (name as NSString).deletingPathExtension + "." + ext
        }
        filter()
    }

    // MARK: Saving

    /// A typed path: "~" and absolute paths as they are, anything else relative to the current folder.
    /// Backslashes count as slashes, so Windows-style paths work too.
    private func resolve(_ text: String) -> URL {
        var path = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\\", with: "/")
        if path.hasPrefix("\""), path.hasSuffix("\""), path.count >= 2 { path = String(path.dropFirst().dropLast()) }
        path = (path as NSString).expandingTildeInPath
        if path.hasPrefix("/") { return URL(fileURLWithPath: path).standardizedFileURL }
        return folder.appendingPathComponent(path).standardizedFileURL
    }

    @objc private func saveClicked() {
        let text = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        var url = resolve(text)
        // A folder (or a path ending in a slash) opens it, as in Windows.
        if isFolder(url) || text.hasSuffix("/") || text.hasSuffix("\\") {
            if isFolder(url) {
                navigate(to: url)
                nameField.stringValue = fileName
            } else {
                alert("The folder '\(url.path)' doesn't exist.")
            }
            return
        }
        let parent = url.deletingLastPathComponent()
        guard isFolder(parent) else {
            alert("\(text)\nPath does not exist.\nCheck the path and try again.")
            return
        }
        let type = types[max(0, typePopup.indexOfSelectedItem)]
        if url.pathExtension.isEmpty, let ext = type.extensions.first { url.appendPathExtension(ext) }
        if FileManager.default.fileExists(atPath: url.path) {
            let confirm = NSAlert()
            confirm.messageText = "Confirm Save As"
            confirm.informativeText = "\(url.lastPathComponent) already exists.\nDo you want to replace it?"
            confirm.addButton(withTitle: "Yes")
            confirm.addButton(withTitle: "No")
            confirm.alertStyle = .warning
            guard confirm.runModal() == .alertFirstButtonReturn else { return }
        }
        UserDefaults.standard.set(parent.path, forKey: rememberKey)
        var names = UserDefaults.standard.stringArray(forKey: rememberKey + ".names") ?? []
        names = Array(([url.lastPathComponent] + names.filter { $0 != url.lastPathComponent }).prefix(15))
        UserDefaults.standard.set(names, forKey: rememberKey + ".names")
        result = Result(url: url, typeIndex: max(0, typePopup.indexOfSelectedItem), extraIndex: max(0, extraPopup.indexOfSelectedItem))
        NSApp.stopModal()
    }

    @objc private func cancelClicked() {
        result = nil
        NSApp.stopModal()
    }

    public func windowWillClose(_ notification: Notification) {
        if NSApp.modalWindow === panel { NSApp.stopModal() }
    }

    private func alert(_ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.alertStyle = .warning
        a.beginSheetModal(for: panel)
    }

    // MARK: Tables

    public func numberOfRows(in tableView: NSTableView) -> Int { tableView === sidebar ? places.count : shown.count }

    public func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { tableView === sidebar && places[row].1 == nil }

    public func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { tableView !== sidebar || places[row].1 != nil }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        guard let tableView = notification.object as? NSTableView else { return }
        if tableView === sidebar {
            let row = sidebar.selectedRow
            if places.indices.contains(row), let url = places[row].1, url.standardizedFileURL != folder { navigate(to: url) }
        } else {
            let row = table.selectedRow
            if shown.indices.contains(row), !shown[row].isFolder { nameField.stringValue = shown[row].url.lastPathComponent }
        }
    }

    public func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) { sort() }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView()
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingMiddle
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(text)
        cell.textField = text
        var leading = cell.leadingAnchor
        if tableView === sidebar {
            let place = places[row]
            text.stringValue = place.0
            if place.1 == nil {
                text.font = .systemFont(ofSize: 11, weight: .semibold)
                text.textColor = .secondaryLabelColor
            } else if let image = NSImage(systemSymbolName: place.2, accessibilityDescription: nil) {
                let icon = NSImageView(image: image)
                icon.contentTintColor = .controlAccentColor
                icon.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(icon)
                NSLayoutConstraint.activate([icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                                             icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                                             icon.widthAnchor.constraint(equalToConstant: 18)])
                leading = icon.trailingAnchor
            }
        } else {
            let item = shown[row]
            switch tableColumn?.identifier.rawValue {
            case "name":
                text.stringValue = item.url.lastPathComponent
                let icon = NSImageView(image: NSWorkspace.shared.icon(forFile: item.url.path))
                icon.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(icon)
                NSLayoutConstraint.activate([icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                                             icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                                             icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16)])
                leading = icon.trailingAnchor
            case "date":
                text.stringValue = item.date.map { DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .short) } ?? ""
            case "type":
                text.stringValue = item.type
            default:
                text.stringValue = item.size.map { "\(NumberFormatter.localizedString(from: NSNumber(value: max(1, ($0 + 1023) / 1024)), number: .decimal)) KB" } ?? ""
                text.alignment = .right
            }
            if tableColumn?.identifier.rawValue != "name" { text.textColor = .secondaryLabelColor }
        }
        NSLayoutConstraint.activate([text.leadingAnchor.constraint(equalTo: leading, constant: 4),
                                     text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                                     text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        return cell
    }

    public func tableView(_ tableView: NSTableView, shouldEdit tableColumn: NSTableColumn?, row: Int) -> Bool { false }
}
