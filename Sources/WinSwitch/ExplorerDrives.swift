import AppKit

/// A mounted disk with its capacity, for This PC and drive Properties.
struct DriveInfo {
    let url: URL
    let name: String
    let total: Int64
    let free: Int64
    let fileSystem: String
    let kind: String
    let icon: NSImage

    var used: Int64 { max(0, total - free) }
    var fraction: Double { total > 0 ? Double(used) / Double(total) : 0 }

    static let keys: Set<URLResourceKey> = [.volumeLocalizedNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
                                            .volumeAvailableCapacityKey, .volumeLocalizedFormatDescriptionKey, .volumeIsInternalKey,
                                            .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsLocalKey, .volumeIsRootFileSystemKey]

    init?(url: URL) {
        guard let v = try? url.resourceValues(forKeys: Self.keys) else { return nil }
        self.url = url
        name = v.volumeLocalizedName ?? url.lastPathComponent
        total = Int64(v.volumeTotalCapacity ?? 0)
        // "Important usage" counts purgeable space as free, like Finder; fall back to the plain figure.
        let important = v.volumeAvailableCapacityForImportantUsage ?? 0
        free = important > 0 ? important : Int64(v.volumeAvailableCapacity ?? 0)
        var fs = statfs()
        fileSystem = statfs(url.path, &fs) == 0
            ? withUnsafeBytes(of: fs.f_fstypename) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }.uppercased()
            : (v.volumeLocalizedFormatDescription ?? "")
        if v.volumeIsLocal == false {
            kind = "Network drive"
        } else if v.volumeIsRemovable == true || v.volumeIsEjectable == true || v.volumeIsInternal == false {
            kind = "Removable disk"
        } else {
            kind = "Local disk"
        }
        icon = NSWorkspace.shared.icon(forFile: url.path)
    }

    static func all() -> [DriveInfo] {
        (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]) ?? [])
            .compactMap(DriveInfo.init(url:))
    }

    /// "245 GB free of 1.99 TB", like Windows.
    var freeText: String { "\(Self.size(free)) free of \(Self.size(total))" }

    static func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    static func isMountPoint(_ url: URL) -> Bool {
        all().contains { $0.url.standardizedFileURL == url.standardizedFileURL }
    }
}

/// Windows' "This PC": the user folders, then the disks with how full they are.
@MainActor
final class DrivesView: NSView {
    var onOpen: ((URL) -> Void)?
    var onProperties: ((URL) -> Void)?
    private(set) var drives: [DriveInfo] = []
    private let stack = NSStackView()
    private var tiles: [Tile] = []
    private(set) var selected: URL?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 18, bottom: 18, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func reload() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        tiles = []
        drives = DriveInfo.all()
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let folders: [(String, String)] = [("Desktop", "Desktop"), ("Documents", "Documents"), ("Downloads", "Downloads"),
                                           ("Music", "Music"), ("Pictures", "Pictures"), ("Videos", "Movies")]
        stack.addArrangedSubview(header("Folders (\(folders.count))"))
        stack.addArrangedSubview(grid(folders.compactMap { title, path in
            let url = home.appendingPathComponent(path)
            guard fm.fileExists(atPath: url.path) else { return nil }
            return Tile(url: url, title: title, icon: NSWorkspace.shared.icon(forFile: url.path), drive: nil, owner: self)
        }))
        stack.addArrangedSubview(header("Devices and drives (\(drives.count))"))
        stack.addArrangedSubview(grid(drives.map { Tile(url: $0.url, title: $0.name, icon: $0.icon, drive: $0, owner: self) }))
    }

    private func header(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func grid(_ items: [Tile]) -> NSView {
        tiles += items
        let rows = stride(from: 0, to: items.count, by: 3).map { start -> NSStackView in
            let row = NSStackView(views: Array(items[start..<min(start + 3, items.count)]))
            row.spacing = 12
            return row
        }
        let column = NSStackView(views: rows)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 10
        return column
    }

    fileprivate func select(_ url: URL?) {
        selected = url
        tiles.forEach { $0.isSelected = $0.url == url }
        window?.makeFirstResponder(self)
    }

    fileprivate func open(_ url: URL) { onOpen?(url) }
    fileprivate func properties(_ url: URL) { onProperties?(url) }

    override func mouseDown(with event: NSEvent) { select(nil) }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36, let selected {   // Enter opens, Alt+Enter shows Properties
            if event.modifierFlags.contains(.option) { onProperties?(selected) } else { onOpen?(selected) }
            return
        }
        // Arrow keys move between tiles.
        if [123, 124, 125, 126].contains(Int(event.keyCode)) {
            let index = tiles.firstIndex { $0.url == selected } ?? -1
            let step = [123: -1, 124: 1, 125: 3, 126: -3][Int(event.keyCode)] ?? 0
            let next = index < 0 ? 0 : min(max(0, index + step), tiles.count - 1)
            if tiles.indices.contains(next) { select(tiles[next].url) }
            return
        }
        super.keyDown(with: event)
    }

    /// One folder or drive. Drives show a capacity bar that turns red when over 90% full.
    final class Tile: NSView {
        let url: URL
        weak var owner: DrivesView?
        var isSelected = false { didSet { needsDisplay = true } }
        private var hovering = false { didSet { needsDisplay = true } }

        init(url: URL, title: String, icon: NSImage, drive: DriveInfo?, owner: DrivesView) {
            self.url = url
            self.owner = owner
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false
            widthAnchor.constraint(equalToConstant: 270).isActive = true
            heightAnchor.constraint(equalToConstant: drive == nil ? 50 : 64).isActive = true
            toolTip = url.path

            let image = NSImageView(image: icon)
            image.imageScaling = .scaleProportionallyUpOrDown
            let name = NSTextField(labelWithString: title)
            name.font = .systemFont(ofSize: 13)
            name.lineBreakMode = .byTruncatingTail
            var lines: [NSView] = [name]
            if let drive {
                let bar = CapacityBar(fraction: drive.fraction)
                bar.translatesAutoresizingMaskIntoConstraints = false
                bar.widthAnchor.constraint(equalToConstant: 196).isActive = true
                bar.heightAnchor.constraint(equalToConstant: 12).isActive = true
                let free = NSTextField(labelWithString: drive.freeText)
                free.font = .systemFont(ofSize: 11)
                free.textColor = .secondaryLabelColor
                lines += [bar, free]
            }
            let text = NSStackView(views: lines)
            text.orientation = .vertical
            text.alignment = .leading
            text.spacing = 3
            let row = NSStackView(views: [image, text])
            row.spacing = 8
            row.translatesAutoresizingMaskIntoConstraints = false
            addSubview(row)
            NSLayoutConstraint.activate([
                image.widthAnchor.constraint(equalToConstant: drive == nil ? 36 : 48), image.heightAnchor.constraint(equalTo: image.widthAnchor),
                row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6), row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
                row.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        }

        required init?(coder: NSCoder) { fatalError() }

        override func draw(_ dirtyRect: NSRect) {
            guard isSelected || hovering else { return }
            let color = NSColor.controlAccentColor.withAlphaComponent(isSelected ? 0.22 : 0.09)
            color.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }

        override func mouseEntered(with event: NSEvent) { hovering = true }
        override func mouseExited(with event: NSEvent) { hovering = false }

        override func mouseDown(with event: NSEvent) {
            owner?.select(url)
            if event.clickCount == 2 { owner?.open(url) }
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            owner?.select(url)
            let menu = NSMenu()
            let open = NSMenuItem(title: "Open", action: #selector(openItem), keyEquivalent: "")
            open.target = self
            let properties = NSMenuItem(title: "Properties", action: #selector(propertiesItem), keyEquivalent: "")
            properties.target = self
            menu.addItem(open)
            if DriveInfo(url: url).map({ $0.kind != "Local disk" }) == true, url.path != "/" {
                let eject = NSMenuItem(title: "Eject", action: #selector(ejectItem), keyEquivalent: "")
                eject.target = self
                menu.addItem(eject)
            }
            menu.addItem(.separator())
            menu.addItem(properties)
            return menu
        }

        @objc private func openItem() { owner?.open(url) }
        @objc private func propertiesItem() { owner?.properties(url) }
        @objc private func ejectItem() {
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: url)
                owner?.reload()
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }
}

/// The used / free bar under a drive: blue, red when nearly full.
final class CapacityBar: NSView {
    let fraction: Double
    init(fraction: Double) {
        self.fraction = fraction
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.quaternaryLabelColor.setFill()
        bounds.fill()
        (fraction > 0.9 ? NSColor.systemRed : NSColor(srgbRed: 0.15, green: 0.52, blue: 0.95, alpha: 1)).setFill()
        NSRect(x: 0, y: 0, width: bounds.width * fraction, height: bounds.height).fill()
        NSColor.separatorColor.setStroke()
        NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)).stroke()
    }
}

/// The donut on a drive's Properties: used in blue, free in pink, like Windows.
final class CapacityPie: NSView {
    let fraction: Double
    static let usedColor = NSColor(srgbRed: 0.15, green: 0.52, blue: 0.95, alpha: 1)
    static let freeColor = NSColor(srgbRed: 0.93, green: 0.55, blue: 0.85, alpha: 1)

    init(fraction: Double) {
        self.fraction = fraction
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let side = min(bounds.width, bounds.height) - 4
        let rect = NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let radius = side / 2
        Self.freeColor.setFill()
        NSBezierPath(ovalIn: rect).fill()
        let used = NSBezierPath()
        used.move(to: center)
        used.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 360 * fraction, clockwise: true)
        used.close()
        Self.usedColor.setFill()
        used.fill()
        // The hole in the middle.
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(ovalIn: rect.insetBy(dx: radius * 0.45, dy: radius * 0.45)).fill()
    }
}

/// The Properties window (Alt+Enter): General facts about files, folders or a drive. Folder sizes are counted in
/// the background, like Windows.
@MainActor
final class PropertiesWindow: NSWindowController, NSWindowDelegate {
    private static var open: [PropertiesWindow] = []
    private let urls: [URL]
    private var counting: Task<Void, Never>?
    private let sizeLabel = NSTextField(labelWithString: "")
    private let diskSizeLabel = NSTextField(labelWithString: "")
    private let containsLabel = NSTextField(labelWithString: "")
    private let readOnly = NSButton(checkboxWithTitle: "Read-only", target: nil, action: nil)
    private let hidden = NSButton(checkboxWithTitle: "Hidden", target: nil, action: nil)
    private var startReadOnly = NSControl.StateValue.off
    private var startHidden = NSControl.StateValue.off
    private var onChange: (() -> Void)?

    static func show(_ urls: [URL], onChange: (() -> Void)? = nil) {
        guard !urls.isEmpty else { return }
        let controller = PropertiesWindow(urls: urls)
        controller.onChange = onChange
        open.append(controller)
        controller.window?.center()
        controller.showWindow(nil)
        if let window = controller.window { Windows.focusOwn(window) }
    }

    private init(urls: [URL]) {
        self.urls = urls
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 480), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        let first = urls[0]
        let name = urls.count == 1 ? (first.path == "/" ? DriveInfo(url: first)?.name ?? "Macintosh HD" : FileManager.default.displayName(atPath: first.path)) : "\(urls.count) items"
        window.title = "\(name) Properties"
        if urls.count == 1, DriveInfo.isMountPoint(first), let drive = DriveInfo(url: first) {
            buildDrive(drive)
        } else {
            buildItems(name)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        counting?.cancel()
        Self.open.removeAll { $0 === self }
    }

    // MARK: Layout helpers

    private func value(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.isSelectable = true
        field.lineBreakMode = .byTruncatingMiddle
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    private func line() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    private func finish(_ rows: [NSView], buttons: [NSButton]) {
        guard let content = window?.contentView else { return }
        let buttonRow = NSStackView(views: [NSView()] + buttons)
        let stack = NSStackView(views: rows + [buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 14, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            content.widthAnchor.constraint(equalToConstant: 400),
        ])
        for view in stack.arrangedSubviews where view is NSBox || view === buttonRow {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36).isActive = true
        }
        content.layoutSubtreeIfNeeded()
        window?.setContentSize(stack.fittingSize)
    }

    private func header(icon: NSImage, name: String) -> NSView {
        let image = NSImageView(image: icon)
        image.widthAnchor.constraint(equalToConstant: 40).isActive = true
        image.heightAnchor.constraint(equalToConstant: 40).isActive = true
        let field = NSTextField(string: name)
        field.isEditable = false
        field.isSelectable = true
        field.widthAnchor.constraint(equalToConstant: 280).isActive = true
        let row = NSStackView(views: [image, field])
        row.spacing = 14
        return row
    }

    private func grid(_ rows: [(String, NSView)]) -> NSGridView {
        let grid = NSGridView(views: rows.map { [NSTextField(labelWithString: $0.0), $0.1] })
        grid.rowSpacing = 7
        grid.columnSpacing = 12
        grid.column(at: 0).width = 100
        grid.column(at: 1).width = 240
        grid.setContentHuggingPriority(.required, for: .vertical)
        return grid
    }

    private func date(_ date: Date?) -> String {
        guard let date else { return "" }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .medium
        return f.string(from: date)
    }

    private static func bytes(_ n: Int64) -> String {
        "\(DriveInfo.size(n)) (\(NumberFormatter.localizedString(from: NSNumber(value: n), number: .decimal)) bytes)"
    }

    // MARK: Drive

    private func buildDrive(_ d: DriveInfo) {
        let usedSwatch = swatch(CapacityPie.usedColor), freeSwatch = swatch(CapacityPie.freeColor)
        let pie = CapacityPie(fraction: d.fraction)
        pie.widthAnchor.constraint(equalToConstant: 130).isActive = true
        pie.heightAnchor.constraint(equalToConstant: 130).isActive = true
        let pieRow = NSView()
        pie.translatesAutoresizingMaskIntoConstraints = false
        pieRow.addSubview(pie)
        NSLayoutConstraint.activate([pie.centerXAnchor.constraint(equalTo: pieRow.centerXAnchor),
                                     pie.topAnchor.constraint(equalTo: pieRow.topAnchor), pie.bottomAnchor.constraint(equalTo: pieRow.bottomAnchor)])
        let caption = value("\(Int((d.fraction * 100).rounded()))% used")
        caption.alignment = .center
        let rows: [NSView] = [
            header(icon: d.icon, name: d.name), line(),
            grid([("Type:", value(d.kind)), ("File system:", value(d.fileSystem))]), line(),
            grid([("Used space:", NSStackView(views: [usedSwatch, value(Self.bytes(d.used))])),
                  ("Free space:", NSStackView(views: [freeSwatch, value(Self.bytes(d.free))]))]), line(),
            grid([("Capacity:", value(Self.bytes(d.total)))]),
            pieRow,
            caption,
        ]
        pieRow.widthAnchor.constraint(equalToConstant: 364).isActive = true
        caption.widthAnchor.constraint(equalToConstant: 364).isActive = true
        let ok = NSButton(title: "OK", target: self, action: #selector(closeWindow))
        ok.keyEquivalent = "\r"
        finish(rows, buttons: [ok])
    }

    private func swatch(_ color: NSColor) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = color.cgColor
        view.widthAnchor.constraint(equalToConstant: 14).isActive = true
        view.heightAnchor.constraint(equalToConstant: 14).isActive = true
        return view
    }

    // MARK: Files and folders

    private func buildItems(_ name: String) {
        let fm = FileManager.default
        let first = urls[0]
        let keys: Set<URLResourceKey> = [.localizedTypeDescriptionKey, .creationDateKey, .contentModificationDateKey,
                                         .contentAccessDateKey, .isHiddenKey, .isDirectoryKey, .isPackageKey, .isWritableKey]
        let values = try? first.resourceValues(forKeys: keys)
        let single = urls.count == 1
        let isFolder = single && values?.isDirectory == true && values?.isPackage != true
        let parent = first.deletingLastPathComponent().path
        let sameParent = urls.allSatisfy { $0.deletingLastPathComponent().path == parent }

        var icon = NSWorkspace.shared.icon(forFiles: urls.map(\.path)) ?? NSWorkspace.shared.icon(forFile: first.path)
        if single { icon = NSWorkspace.shared.icon(forFile: first.path) }
        var facts: [(String, NSView)] = [
            ("Type:", value(single ? (values?.localizedTypeDescription ?? (isFolder ? "File folder" : "File")) : "Multiple types")),
            ("Location:", value(sameParent ? parent : "Various folders")),
            ("Size:", sizeLabel),
            ("Size on disk:", diskSizeLabel),
        ]
        if !single || isFolder { facts.append(("Contains:", containsLabel)) }
        var rows: [NSView] = [header(icon: icon, name: name), line(), grid(facts), line()]
        if single {
            rows += [grid([("Created:", value(date(values?.creationDate))), ("Modified:", value(date(values?.contentModificationDate))),
                           ("Accessed:", value(date(values?.contentAccessDate)))]), line()]
        }
        // Attributes: on folders Read-only only affects the files' write permission in Windows; here it applies to the
        // items themselves.
        let allHidden = urls.allSatisfy { (try? $0.resourceValues(forKeys: [.isHiddenKey]).isHidden) == true }
        let allReadOnly = urls.allSatisfy { !fm.isWritableFile(atPath: $0.path) }
        startHidden = allHidden ? .on : .off
        startReadOnly = allReadOnly ? .on : .off
        hidden.state = startHidden
        readOnly.state = startReadOnly
        let attributes = NSStackView(views: [readOnly, hidden])
        attributes.spacing = 16
        rows.append(grid([("Attributes:", attributes)]))

        sizeLabel.stringValue = "Calculating..."
        diskSizeLabel.stringValue = "Calculating..."
        containsLabel.stringValue = "Calculating..."
        count()

        let ok = NSButton(title: "OK", target: self, action: #selector(okClicked))
        ok.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(closeWindow))
        cancel.keyEquivalent = "\u{1b}"
        let apply = NSButton(title: "Apply", target: self, action: #selector(applyClicked))
        finish(rows, buttons: [ok, cancel, apply])
    }

    /// Walks the items in the background and updates the labels as it goes.
    private func count() {
        let urls = self.urls
        let report: @MainActor @Sendable ((Int64, Int64, Int, Int), Bool) -> Void = { [weak self] counts, done in
            self?.showCount(counts, done: done)
        }
        counting = Task.detached(priority: .userInitiated) {
            var size: Int64 = 0, onDisk: Int64 = 0, files = 0, folders = 0
            var lastUpdate = Date()
            let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .totalFileAllocatedSizeKey]
            func add(_ url: URL) {
                guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return }
                if v.isDirectory == true && v.isSymbolicLink != true { folders += 1; return }
                files += 1
                size += Int64(v.fileSize ?? 0)
                onDisk += Int64(v.totalFileAllocatedSize ?? v.fileSize ?? 0)
            }
            for url in urls {
                let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard v?.isDirectory == true, v?.isSymbolicLink != true else { add(url); continue }
                if urls.count > 1 { folders += 1 }
                let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [])
                while let item = walker?.nextObject() as? URL {
                    if Task.isCancelled { return }
                    add(item)
                    if Date().timeIntervalSince(lastUpdate) > 0.3 {
                        lastUpdate = Date()
                        let snapshot = (size, onDisk, files, folders)
                        await report(snapshot, false)
                    }
                }
            }
            let result = (size, onDisk, files, folders)
            await report(result, true)
        }
    }

    private func showCount(_ c: (Int64, Int64, Int, Int), done: Bool) {
        let more = done ? "" : "..."
        sizeLabel.stringValue = Self.bytes(c.0) + more
        diskSizeLabel.stringValue = Self.bytes(c.1) + more
        let n = NumberFormatter()
        n.numberStyle = .decimal
        containsLabel.stringValue = "\(n.string(from: NSNumber(value: c.2)) ?? "0") Files, \(n.string(from: NSNumber(value: c.3)) ?? "0") Folders" + more
    }

    // MARK: Buttons

    @objc private func okClicked() {
        if applyChanges() { close() }
    }

    @objc private func applyClicked() { _ = applyChanges() }

    @objc private func closeWindow() { close() }

    private func applyChanges() -> Bool {
        let fm = FileManager.default
        do {
            if hidden.state != startHidden {
                for var url in urls {
                    var values = URLResourceValues()
                    values.isHidden = hidden.state == .on
                    try url.setResourceValues(values)
                }
                startHidden = hidden.state
            }
            if readOnly.state != startReadOnly {
                for url in urls {
                    let attributes = try fm.attributesOfItem(atPath: url.path)
                    let mode = (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o644
                    let newMode = readOnly.state == .on ? mode & ~0o222 : mode | 0o200
                    try fm.setAttributes([.posixPermissions: NSNumber(value: newMode)], ofItemAtPath: url.path)
                }
                startReadOnly = readOnly.state
            }
        } catch {
            NSAlert(error: error).runModal()
            return false
        }
        onChange?()
        return true
    }
}
