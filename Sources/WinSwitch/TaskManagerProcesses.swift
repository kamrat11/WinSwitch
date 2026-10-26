import AppKit

/// Icons for processes: the app's icon for anything inside an app bundle, a terminal icon otherwise.
@MainActor
enum ProcessIcons {
    private static var cache: [String: NSImage] = [:]
    private static let executable: NSImage = {
        let image = NSWorkspace.shared.icon(for: .unixExecutable)
        image.size = NSSize(width: 16, height: 16)
        return image
    }()

    static func icon(for path: String) -> NSImage {
        guard let bundle = ProcessActions.bundlePath(of: path) else { return executable }
        if let image = cache[bundle] { return image }
        let image = NSWorkspace.shared.icon(forFile: bundle)
        image.size = NSSize(width: 16, height: 16)
        cache[bundle] = image
        return image
    }

    private static var descriptions: [String: String] = [:]

    /// "Description" in the Details tab: the name of the app a process belongs to.
    static func description(for path: String) -> String {
        guard let bundlePath = ProcessActions.bundlePath(of: path) else { return "" }
        if let cached = descriptions[bundlePath] { return cached }
        let info = Bundle(path: bundlePath)?.localizedInfoDictionary ?? Bundle(path: bundlePath)?.infoDictionary
        let name = info?["CFBundleDisplayName"] as? String ?? info?["CFBundleName"] as? String
            ?? ((bundlePath as NSString).lastPathComponent as NSString).deletingPathExtension
        descriptions[bundlePath] = name
        return name
    }
}

enum ProcessText {
    static func cpu(_ value: Double) -> String { value < 0.0005 ? "0%" : Format.percent(value) }
    static func memory(_ value: UInt64?) -> String {
        guard let value else { return "" }
        return String(format: "%.1f MB", Double(value) / 1024 / 1024)
    }
    static func disk(_ value: Double) -> String {
        value < 0.05 * 1024 * 1024 ? "0 MB/s" : String(format: "%.1f MB/s", value / 1024 / 1024)
    }
    static func cpuHeat(_ value: Double) -> Double { min(1, value * 4) }
    static func memoryHeat(_ value: UInt64?) -> Double {
        guard let value, MachineInfo.memorySize > 0 else { return 0 }
        return min(1, Double(value) / Double(MachineInfo.memorySize) * 12)
    }
    static func diskHeat(_ value: Double) -> Double { min(1, value / (40 * 1024 * 1024)) }

    static func systemPath(_ path: String) -> Bool {
        path.isEmpty || ["/System/", "/usr/", "/bin/", "/sbin/", "/Library/Apple/", "/private/"].contains { path.hasPrefix($0) }
    }
}

// MARK: - Processes

final class ProcNode: NSObject {
    enum Kind { case group, app, process }
    let key: String
    let kind: Kind
    var name = ""
    var icon: NSImage?
    var status = ""
    var cpu = 0.0
    var memory: UInt64 = 0
    var disk = 0.0
    var pid: pid_t = 0
    var path = ""
    var app: NSRunningApplication?
    var system = false
    var children: [ProcNode] = []

    init(key: String, kind: Kind) {
        self.key = key
        self.kind = kind
    }
}

@MainActor
final class ProcessesPage: TMPage, NSOutlineViewDataSource, NSOutlineViewDelegate {
    override var title: String { "Processes" }
    override var symbol: String { "square.grid.2x2" }
    override var actions: [NSView] { [runButton, endButton] }

    private let outline = TMOutlineView()
    private lazy var runButton = TMUI.button("Run new task", symbol: "plus.app", target: self, action: #selector(runNewTask))
    private lazy var endButton = TMUI.button("End task", symbol: "xmark.circle", target: self, action: #selector(endTask(_:)))
    private var roots: [ProcNode] = []
    private var nodes: [String: ProcNode] = [:]
    private var expanded: Set<String> = []
    private var collapsedGroups: Set<String> = []
    private var reloading = false
    private var filter = ""
    private var snapshot = SystemSnapshot()

    override init() {
        super.init()
        let columns = [
            TMUI.column("name", "Name", width: 300),
            TMUI.column("status", "Status", width: 110),
            TMUI.column("pid", "PID", width: 70, right: true),
            TMUI.column("cpu", "CPU", width: 80, right: true),
            TMUI.column("memory", "Memory", width: 105, right: true),
            TMUI.column("disk", "Disk", width: 90, right: true),
        ]
        for column in columns { outline.addTableColumn(column) }
        outline.outlineTableColumn = columns[0]
        TMUI.makeHeader(for: outline, tall: true)
        outline.headerView?.menu = TMUI.columnMenu(for: outline, optional: ["pid"], defaultsKey: "taskManagerProcessesHidden")
        outline.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        outline.rowHeight = 24
        outline.usesAlternatingRowBackgroundColors = false
        outline.gridStyleMask = [.solidVerticalGridLineMask]
        outline.gridColor = NSColor.separatorColor.withAlphaComponent(0.3)
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.autosaveName = "WinSwitchTaskManagerProcesses"
        outline.autosaveTableColumns = true
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(doubleClicked)
        outline.onDelete = { [weak self] in self?.endTask(nil) }
        outline.menuForRow = { [weak self] row in self?.menu(for: row) }

        let scroll = TMUI.scroll(outline)
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        updateButtons()
    }

    override func filterChanged(_ text: String) { filter = text.trimmingCharacters(in: .whitespaces).lowercased() }

    // MARK: Building the tree

    override func update(_ snapshot: SystemSnapshot) {
        self.snapshot = snapshot
        guard !snapshot.processes.isEmpty else { return }
        let me = getuid()
        var byPid: [pid_t: ProcessSample] = [:]
        for p in snapshot.processes { byPid[p.pid] = p }

        let apps = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated && $0.processIdentifier > 0 }
        var appByPid: [pid_t: NSRunningApplication] = [:]
        var appByBundle: [String: NSRunningApplication] = [:]
        for app in apps {
            appByPid[app.processIdentifier] = app
            if let path = app.bundleURL?.path, appByBundle[path] == nil { appByBundle[path] = app }
        }

        // Each process belongs to the nearest app above it (helpers, a terminal's shells), or to the app bundle it is in.
        var members: [pid_t: [ProcessSample]] = [:]
        var loose: [ProcessSample] = []
        for p in snapshot.processes {
            var owner: pid_t?
            var cursor = p.pid
            for _ in 0..<32 {
                if appByPid[cursor] != nil { owner = cursor; break }
                guard let parent = byPid[cursor]?.ppid, parent > 1, parent != cursor else { break }
                cursor = parent
            }
            if owner == nil, let bundle = ProcessActions.bundlePath(of: p.path), let app = appByBundle[bundle] {
                owner = app.processIdentifier
            }
            if let owner { members[owner, default: []].append(p) } else { loose.append(p) }
        }

        var appNodes: [ProcNode] = [], backgroundNodes: [ProcNode] = [], systemNodes: [ProcNode] = []
        for app in apps {
            let pid = app.processIdentifier
            guard let group = members[pid], let main = byPid[pid] else { continue }
            let node = self.node("app:\(pid)", .app)
            node.name = app.localizedName ?? main.name
            node.icon = app.icon
            node.icon?.size = NSSize(width: 16, height: 16)
            node.pid = pid
            node.path = main.path
            node.app = app
            node.system = main.uid != me || ProcessTextIsSystemApp(app)
            node.children = group.count > 1 ? group.map { processNode($0) } : []
            node.cpu = group.reduce(0) { $0 + $1.cpu }
            node.memory = group.reduce(0) { $0 + ($1.memory ?? 0) }
            node.disk = group.reduce(0) { $0 + $1.diskRate }
            if main.state == .suspended {
                node.status = "Suspended"
            } else if app.activationPolicy == .regular && ProcessActions.isNotResponding(pid) {
                node.status = "Not responding"
            } else {
                node.status = ""
            }
            guard matches(node) else { continue }
            if app.activationPolicy == .regular { appNodes.append(node) }
            else if node.system { systemNodes.append(node) }
            else { backgroundNodes.append(node) }
        }
        for p in loose {
            let node = processNode(p)
            guard matches(node) else { continue }
            if node.system { systemNodes.append(node) } else { backgroundNodes.append(node) }
        }

        var newRoots: [ProcNode] = []
        for (key, title, list) in [("g:apps", "Apps", appNodes), ("g:background", "Background processes", backgroundNodes),
                                   ("g:system", "macOS processes", systemNodes)] where !list.isEmpty {
            let group = node(key, .group)
            group.name = "\(title) (\(list.count))"
            group.children = sorted(list)
            newRoots.append(group)
        }
        roots = newRoots
        for node in nodes.values where node.kind == .app { node.children = sorted(node.children) }

        let totals = ["cpu": Format.percent(snapshot.cpuTotal, decimals: 0),
                      "memory": Format.percent(snapshot.memory.usedFraction, decimals: 0),
                      "disk": Format.percent(snapshot.disks.map(\.activeTime).max() ?? 0, decimals: 0)]
        TMUI.updateHeaders(outline, totals: totals)
        reload()
    }

    private func processNode(_ p: ProcessSample) -> ProcNode {
        let node = self.node("p:\(p.pid):\(p.startTime.timeIntervalSince1970)", .process)
        node.name = p.name
        node.icon = ProcessIcons.icon(for: p.path)
        node.pid = p.pid
        node.path = p.path
        node.cpu = p.cpu
        node.memory = p.memory ?? 0
        node.disk = p.diskRate
        node.status = p.state == .suspended ? "Suspended" : ""
        node.system = p.uid != getuid() || ProcessText.systemPath(p.path)
        return node
    }

    private func node(_ key: String, _ kind: ProcNode.Kind) -> ProcNode {
        if let node = nodes[key] { return node }
        let node = ProcNode(key: key, kind: kind)
        nodes[key] = node
        return node
    }

    private func matches(_ node: ProcNode) -> Bool {
        guard !filter.isEmpty else { return true }
        func hit(_ n: ProcNode) -> Bool {
            n.name.lowercased().contains(filter) || String(n.pid) == filter || n.path.lowercased().contains(filter)
        }
        return hit(node) || node.children.contains(where: hit)
    }

    private func sorted(_ list: [ProcNode]) -> [ProcNode] {
        let sort = outline.sortDescriptors.first ?? NSSortDescriptor(key: "name", ascending: true)
        return list.sorted { a, b in
            let ordered: Bool
            switch sort.key {
            case "cpu": ordered = a.cpu == b.cpu ? a.name < b.name : a.cpu < b.cpu
            case "memory": ordered = a.memory == b.memory ? a.name < b.name : a.memory < b.memory
            case "disk": ordered = a.disk == b.disk ? a.name < b.name : a.disk < b.disk
            case "pid": ordered = a.pid < b.pid
            case "status": ordered = a.status == b.status ? a.name < b.name : a.status < b.status
            default: ordered = a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            return sort.ascending ? ordered : !ordered
        }
    }

    private func reload() {
        reloading = true
        let selectedKey = (outline.item(atRow: outline.selectedRow) as? ProcNode)?.key
        outline.reloadData()
        for group in roots where !collapsedGroups.contains(group.key) {
            outline.expandItem(group)
            for child in group.children where expanded.contains(child.key) { outline.expandItem(child) }
        }
        if let selectedKey, let node = nodes[selectedKey] {
            let row = outline.row(forItem: node)
            if row >= 0 { outline.selectRowIndexes([row], byExtendingSelection: false) }
        }
        reloading = false
        // Drop nodes of processes that are gone, now that the outline no longer shows them.
        if nodes.count > 3000 {
            var live = Set<String>()
            for group in roots { live.insert(group.key); for c in group.children { live.insert(c.key); c.children.forEach { live.insert($0.key) } } }
            nodes = nodes.filter { live.contains($0.key) }
        }
        updateButtons()
    }

    // MARK: Outline data

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? ProcNode else { return roots.count }
        return node.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? ProcNode else { return roots[index] }
        return node.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? ProcNode)?.children.isEmpty ?? true)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? ProcNode, let id = tableColumn?.identifier else { return nil }
        if id.rawValue == "name" {
            let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? IconCell ?? IconCell(identifier: id)
            cell.label.stringValue = node.name
            cell.label.font = node.kind == .group ? .systemFont(ofSize: 12, weight: .semibold) : .systemFont(ofSize: 12)
            cell.icon.image = node.kind == .group ? nil : node.icon
            cell.icon.isHidden = node.kind == .group
            return cell
        }
        let right = id.rawValue != "status"
        let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? HeatCell ?? HeatCell(identifier: id, alignment: right ? .right : .left)
        cell.heat = 0
        cell.shaded = node.kind != .group && ["cpu", "memory", "disk"].contains(id.rawValue)
        guard node.kind != .group else { cell.label.stringValue = ""; return cell }
        switch id.rawValue {
        case "status":
            cell.label.stringValue = node.status
            cell.label.textColor = node.status == "Not responding" ? .systemRed : .secondaryLabelColor
        case "pid":
            cell.label.stringValue = node.kind == .app && !node.children.isEmpty ? "" : String(node.pid)
        case "cpu":
            cell.label.stringValue = ProcessText.cpu(node.cpu)
            cell.heat = ProcessText.cpuHeat(node.cpu)
        case "memory":
            cell.label.stringValue = ProcessText.memory(node.memory)
            cell.heat = ProcessText.memoryHeat(node.memory)
        case "disk":
            cell.label.stringValue = ProcessText.disk(node.disk)
            cell.heat = ProcessText.diskHeat(node.disk)
        default:
            break
        }
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { (item as? ProcNode)?.kind != .group }

    func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        update(snapshot)
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard !reloading, let node = notification.userInfo?["NSObject"] as? ProcNode else { return }
        if node.kind == .group { collapsedGroups.remove(node.key) } else { expanded.insert(node.key) }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !reloading, let node = notification.userInfo?["NSObject"] as? ProcNode else { return }
        if node.kind == .group { collapsedGroups.insert(node.key) } else { expanded.remove(node.key) }
    }

    func outlineViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    // MARK: Actions

    private var selected: ProcNode? {
        let node = outline.item(atRow: outline.selectedRow) as? ProcNode
        return node?.kind == .group ? nil : node
    }

    private func updateButtons() { endButton.isEnabled = selected != nil }

    @objc private func runNewTask() { RunDialog.shared.show() }

    @objc private func doubleClicked() {
        guard let node = outline.item(atRow: outline.clickedRow) as? ProcNode else { return }
        if outline.isExpandable(node) {
            outline.isItemExpanded(node) ? outline.collapseItem(node) : outline.expandItem(node)
        } else if node.kind == .app {
            switchTo(nil)
        }
    }

    override func endTask(_ sender: Any?) {
        guard let node = selected else { return }
        if node.system && !ProcessActions.confirm("Do you want to end the macOS process \"\(node.name)\"?",
                                                  "Ending this process may make macOS unstable or sign you out. Unsaved data will be lost.",
                                                  button: "End process") { return }
        if node.kind == .app, let app = node.app {
            ProcessActions.endApp(app)
        } else {
            ProcessActions.endProcess(node.pid, name: node.name)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.manager?.refresh() }
    }

    @objc private func switchTo(_ sender: Any?) {
        guard let app = selected?.app else { return }
        app.unhide()
        app.activate()
    }

    @objc private func goToDetails(_ sender: Any?) {
        guard let pid = selected?.pid else { return }
        manager?.showPage(DetailsPage.self)?.select(pid: pid)
    }

    @objc private func openFileLocation(_ sender: Any?) { ProcessActions.openFileLocation(selected?.path ?? "") }
    @objc private func searchOnline(_ sender: Any?) { ProcessActions.searchOnline(selected?.name ?? "") }

    private func menu(for row: Int) -> NSMenu? {
        guard let node = outline.item(atRow: row) as? ProcNode, node.kind != .group else { return nil }
        let menu = NSMenu()
        if node.kind == .app && node.app?.activationPolicy == .regular {
            menu.addItem(withTitle: "Switch to", action: #selector(switchTo(_:)), keyEquivalent: "").target = self
        }
        menu.addItem(withTitle: "End task", action: #selector(endTask(_:)), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Go to details", action: #selector(goToDetails(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Open file location", action: #selector(openFileLocation(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Search online", action: #selector(searchOnline(_:)), keyEquivalent: "").target = self
        return menu
    }
}

/// Menu bar extras and other agents that ship with macOS go to "macOS processes".
@MainActor
private func ProcessTextIsSystemApp(_ app: NSRunningApplication) -> Bool {
    guard app.activationPolicy != .regular, let path = app.bundleURL?.path else { return false }
    return ProcessText.systemPath(path)
}

// MARK: - Details

@MainActor
final class DetailsPage: TMPage, NSTableViewDataSource, NSTableViewDelegate {
    override var title: String { "Details" }
    override var symbol: String { "list.bullet" }
    override var actions: [NSView] { [runButton, endButton] }

    private let table = TMTableView()
    private lazy var runButton = TMUI.button("Run new task", symbol: "plus.app", target: self, action: #selector(runNewTask))
    private lazy var endButton = TMUI.button("End task", symbol: "xmark.circle", target: self, action: #selector(endTask(_:)))
    private var rows: [ProcessSample] = []
    private var all: [ProcessSample] = []
    private var filter = ""
    private var pendingSelection: pid_t?
    private var notResponding: Set<pid_t> = []

    override init() {
        super.init()
        for column in [
            TMUI.column("name", "Name", width: 220),
            TMUI.column("pid", "PID", width: 70, right: true),
            TMUI.column("status", "Status", width: 105),
            TMUI.column("user", "User name", width: 110),
            TMUI.column("cpu", "CPU", width: 60, right: true),
            TMUI.column("cputime", "CPU time", width: 85, right: true),
            TMUI.column("memory", "Memory", width: 100, right: true),
            TMUI.column("threads", "Threads", width: 65, right: true),
            TMUI.column("arch", "Architecture", width: 105),
            TMUI.column("priority", "Base priority", width: 100),
            TMUI.column("description", "Description", width: 170),
            TMUI.column("path", "Image path name", width: 360),
        ] { table.addTableColumn(column) }
        TMUI.makeHeader(for: table, tall: false)
        table.headerView?.menu = TMUI.columnMenu(for: table, optional: ["cputime", "priority", "path"], defaultsKey: "taskManagerDetailsHidden")
        table.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        table.rowHeight = 22
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.autosaveName = "WinSwitchTaskManagerDetails"
        table.autosaveTableColumns = true
        table.dataSource = self
        table.delegate = self
        table.onDelete = { [weak self] in self?.endTask(nil) }
        table.menuForRow = { [weak self] row in self?.menu(for: row) }

        let scroll = TMUI.scroll(table)
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        endButton.isEnabled = false
    }

    func select(pid: pid_t) {
        pendingSelection = pid
        update(manager?.snapshot ?? SystemSnapshot())
    }

    override func filterChanged(_ text: String) { filter = text.trimmingCharacters(in: .whitespaces).lowercased() }

    override func update(_ snapshot: SystemSnapshot) {
        all = snapshot.processes
        notResponding = Set(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
            .map(\.processIdentifier).filter { ProcessActions.isNotResponding($0) })
        var list = all
        if !filter.isEmpty {
            list = list.filter { $0.name.lowercased().contains(filter) || String($0.pid) == filter || $0.path.lowercased().contains(filter)
                || ProcessIcons.description(for: $0.path).lowercased().contains(filter) }
        }
        let sort = table.sortDescriptors.first ?? NSSortDescriptor(key: "name", ascending: true)
        list.sort { a, b in
            let ordered: Bool
            switch sort.key {
            case "pid": ordered = a.pid < b.pid
            case "status": ordered = statusText(a) < statusText(b)
            case "user": ordered = MachineInfo.userName(a.uid) < MachineInfo.userName(b.uid)
            case "cpu": ordered = a.cpu == b.cpu ? a.pid < b.pid : a.cpu < b.cpu
            case "cputime": ordered = a.cpuTime < b.cpuTime
            case "memory": ordered = (a.memory ?? 0) < (b.memory ?? 0)
            case "threads": ordered = (a.threads ?? 0) < (b.threads ?? 0)
            case "arch": ordered = a.translated == b.translated ? a.pid < b.pid : !a.translated
            case "priority": ordered = a.nice < b.nice
            case "description": ordered = ProcessIcons.description(for: a.path) < ProcessIcons.description(for: b.path)
            case "path": ordered = a.path < b.path
            default: ordered = a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            return sort.ascending ? ordered : !ordered
        }
        let selectedPid = pendingSelection ?? (table.selectedRow >= 0 && table.selectedRow < rows.count ? rows[table.selectedRow].pid : nil)
        rows = list
        table.reloadData()
        TMUI.updateHeaders(table, totals: [:])
        if let selectedPid, let index = rows.firstIndex(where: { $0.pid == selectedPid }) {
            table.selectRowIndexes([index], byExtendingSelection: false)
            if pendingSelection != nil { table.scrollRowToVisible(index); view.window?.makeFirstResponder(table) }
        }
        pendingSelection = nil
        endButton.isEnabled = table.selectedRow >= 0
    }

    private func statusText(_ p: ProcessSample) -> String {
        switch p.state {
        case .suspended: return "Suspended"
        case .zombie: return "Zombie"
        default: return notResponding.contains(p.pid) ? "Not responding" : "Running"
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier, row < rows.count else { return nil }
        let p = rows[row]
        if id.rawValue == "name" {
            let cell = tableView.makeView(withIdentifier: id, owner: nil) as? IconCell ?? IconCell(identifier: id)
            cell.label.stringValue = p.name
            cell.label.font = .systemFont(ofSize: 12)
            cell.icon.image = ProcessIcons.icon(for: p.path)
            return cell
        }
        let right = ["pid", "cpu", "cputime", "memory", "threads"].contains(id.rawValue)
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? HeatCell ?? HeatCell(identifier: id, alignment: right ? .right : .left)
        cell.label.textColor = .labelColor
        let text: String
        switch id.rawValue {
        case "pid": text = String(p.pid)
        case "status":
            text = statusText(p)
            if text == "Not responding" { cell.label.textColor = .systemRed }
        case "user": text = MachineInfo.userName(p.uid)
        case "cpu": text = String(format: "%02.0f", p.cpu * 100)
        case "cputime": text = Format.cpuTime(p.cpuTime)
        case "memory": text = p.memory.map { String(format: "%@ K", NumberFormatter.localizedString(from: NSNumber(value: $0 / 1024), number: .decimal)) } ?? ""
        case "threads": text = p.threads.map(String.init) ?? ""
        case "arch": text = p.translated ? "Intel (Rosetta)" : "Apple silicon"
        case "priority": text = ProcessActions.priorityName(p.nice)
        case "description": text = ProcessIcons.description(for: p.path)
        case "path": text = p.path
        default: text = ""
        }
        cell.label.stringValue = text
        return cell
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        update(manager?.snapshot ?? SystemSnapshot())
    }

    func tableViewSelectionDidChange(_ notification: Notification) { endButton.isEnabled = table.selectedRow >= 0 }

    // MARK: Actions

    private var selected: ProcessSample? { table.selectedRow >= 0 && table.selectedRow < rows.count ? rows[table.selectedRow] : nil }

    @objc private func runNewTask() { RunDialog.shared.show() }

    override func endTask(_ sender: Any?) {
        guard let p = selected,
              ProcessActions.confirm("Do you want to end \(p.name)?",
                                     "If an open program is associated with this process, it will close and you will lose any unsaved data.",
                                     button: "End process") else { return }
        ProcessActions.endProcess(p.pid, name: p.name)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.manager?.refresh() }
    }

    @objc private func endTree(_ sender: Any?) {
        guard let p = selected,
              ProcessActions.confirm("Do you want to end the process tree of \(p.name)?",
                                     "This ends \(p.name) and every process it started. Unsaved data will be lost.",
                                     button: "End process tree") else { return }
        ProcessActions.endTree(p.pid, name: p.name, in: all)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.manager?.refresh() }
    }

    @objc private func toggleSuspend(_ sender: Any?) {
        guard let p = selected else { return }
        ProcessActions.setSuspended(p.pid, name: p.name, p.state != .suspended)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.manager?.refresh() }
    }

    @objc private func setPriority(_ sender: NSMenuItem) {
        guard let p = selected, let nice = sender.representedObject as? Int32 else { return }
        ProcessActions.setPriority(p.pid, name: p.name, nice: nice)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.manager?.refresh() }
    }

    @objc private func openFileLocation(_ sender: Any?) { ProcessActions.openFileLocation(selected?.path ?? "") }
    @objc private func searchOnline(_ sender: Any?) { ProcessActions.searchOnline(selected?.name ?? "") }
    @objc private func copyPath(_ sender: Any?) {
        guard let p = selected else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(p.path.isEmpty ? p.name : p.path, forType: .string)
    }

    private func menu(for row: Int) -> NSMenu? {
        guard row < rows.count else { return nil }
        let p = rows[row]
        let menu = NSMenu()
        menu.addItem(withTitle: "End task", action: #selector(endTask(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "End process tree", action: #selector(endTree(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: p.state == .suspended ? "Resume process" : "Suspend process", action: #selector(toggleSuspend(_:)), keyEquivalent: "").target = self
        let priority = NSMenuItem(title: "Set priority", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let current = ProcessActions.priorityName(p.nice)
        for entry in ProcessActions.priorities {
            let item = NSMenuItem(title: entry.title, action: #selector(setPriority(_:)), keyEquivalent: "")
            item.representedObject = entry.nice
            item.target = self
            item.state = entry.title == current ? .on : .off
            sub.addItem(item)
        }
        priority.submenu = sub
        menu.addItem(priority)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open file location", action: #selector(openFileLocation(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Search online", action: #selector(searchOnline(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Copy path", action: #selector(copyPath(_:)), keyEquivalent: "").target = self
        return menu
    }
}

// MARK: - Users

@MainActor
final class UsersPage: TMPage, NSTableViewDataSource, NSTableViewDelegate {
    override var title: String { "Users" }
    override var symbol: String { "person.2" }
    override var searchable: Bool { false }

    private struct Row { let uid: uid_t; let name: String; let status: String; var cpu = 0.0; var memory: UInt64 = 0; var disk = 0.0; var count = 0 }
    private let table = TMTableView()
    private var rows: [Row] = []

    override init() {
        super.init()
        for column in [
            TMUI.column("user", "User", width: 260),
            TMUI.column("status", "Status", width: 110),
            TMUI.column("count", "Processes", width: 90, right: true),
            TMUI.column("cpu", "CPU", width: 80, right: true),
            TMUI.column("memory", "Memory", width: 110, right: true),
            TMUI.column("disk", "Disk", width: 90, right: true),
        ] { table.addTableColumn(column) }
        TMUI.makeHeader(for: table, tall: true)
        table.sortDescriptors = [NSSortDescriptor(key: "cpu", ascending: false)]
        table.rowHeight = 24
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        let scroll = TMUI.scroll(table)
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    override func update(_ snapshot: SystemSnapshot) {
        var byUser: [uid_t: Row] = [:]
        let me = getuid()
        for p in snapshot.processes {
            var row = byUser[p.uid] ?? Row(uid: p.uid,
                                          name: p.uid == me ? "\(NSFullUserName()) (\(NSUserName()))" : MachineInfo.userName(p.uid),
                                          status: p.uid == me ? "Active" : "")
            row.cpu += p.cpu
            row.memory += p.memory ?? 0
            row.disk += p.diskRate
            row.count += 1
            byUser[p.uid] = row
        }
        let sort = table.sortDescriptors.first ?? NSSortDescriptor(key: "cpu", ascending: false)
        rows = byUser.values.sorted { a, b in
            let ordered: Bool
            switch sort.key {
            case "user": ordered = a.uid == me || (b.uid != me && a.name < b.name)
            case "count": ordered = a.count < b.count
            case "memory": ordered = a.memory < b.memory
            case "disk": ordered = a.disk < b.disk
            case "status": ordered = a.status < b.status
            default: ordered = a.cpu < b.cpu
            }
            return sort.ascending ? ordered : !ordered
        }
        TMUI.updateHeaders(table, totals: ["cpu": Format.percent(snapshot.cpuTotal, decimals: 0),
                                           "memory": Format.percent(snapshot.memory.usedFraction, decimals: 0),
                                           "disk": Format.percent(snapshot.disks.map(\.activeTime).max() ?? 0, decimals: 0)])
        table.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier, row < rows.count else { return nil }
        let r = rows[row]
        if id.rawValue == "user" {
            let cell = tableView.makeView(withIdentifier: id, owner: nil) as? IconCell ?? IconCell(identifier: id)
            cell.label.stringValue = r.name
            cell.label.font = .systemFont(ofSize: 12, weight: r.uid == getuid() ? .semibold : .regular)
            cell.icon.image = NSImage(systemSymbolName: r.uid == 0 ? "lock.shield" : "person.crop.circle", accessibilityDescription: nil)
            return cell
        }
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? HeatCell ?? HeatCell(identifier: id, alignment: id.rawValue == "status" ? .left : .right)
        cell.shaded = ["cpu", "memory", "disk"].contains(id.rawValue)
        switch id.rawValue {
        case "status": cell.label.stringValue = r.status; cell.heat = 0
        case "count": cell.label.stringValue = String(r.count); cell.heat = 0
        case "cpu": cell.label.stringValue = ProcessText.cpu(r.cpu); cell.heat = ProcessText.cpuHeat(r.cpu)
        case "memory": cell.label.stringValue = ProcessText.memory(r.memory); cell.heat = ProcessText.memoryHeat(r.memory) / 4
        case "disk": cell.label.stringValue = ProcessText.disk(r.disk); cell.heat = ProcessText.diskHeat(r.disk)
        default: break
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        update(manager?.snapshot ?? SystemSnapshot())
    }
}
