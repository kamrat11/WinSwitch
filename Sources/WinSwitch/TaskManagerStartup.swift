import AppKit
import Security

/// Runs a command-line tool and returns its exit status and output.
enum Shell {
    @discardableResult
    static func run(_ tool: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        guard (try? process.run()) != nil else { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Who signed a program, for the Publisher column: "Apple Inc.", "Google LLC"...
    static func publisher(of path: String) -> String {
        var code: SecStaticCode?
        guard !path.isEmpty, SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code else { return "" }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let certificates = dict[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certificates.first,
              let summary = SecCertificateCopySubjectSummary(leaf) as String? else { return "" }
        if summary == "Software Signing" || summary.hasPrefix("Apple Mac OS") || summary.hasPrefix("Apple iPhone OS") { return "Apple Inc." }
        var name = summary
        for prefix in ["Developer ID Application: ", "Apple Development: ", "Apple Distribution: ", "Mac Developer: ", "3rd Party Mac Developer Application: "]
            where name.hasPrefix(prefix) { name = String(name.dropFirst(prefix.count)) }
        if let paren = name.range(of: " (", options: .backwards), name.hasSuffix(")") { name = String(name[..<paren.lowerBound]) }
        return name
    }

    /// labels -> disabled, from `launchctl print-disabled <domain>`.
    static func disabledLabels(_ domain: String) -> [String: Bool] {
        var result: [String: Bool] = [:]
        for line in run("/bin/launchctl", ["print-disabled", domain]).output.split(separator: "\n") {
            let parts = line.components(separatedBy: "\" => ")
            guard parts.count == 2, let label = parts[0].split(separator: "\"").last else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            result[String(label)] = value == "disabled" || value == "true"
        }
        return result
    }
}

// MARK: - Startup apps

@MainActor
final class StartupPage: TMPage, NSTableViewDataSource, NSTableViewDelegate {
    override var title: String { "Startup apps" }
    override var symbol: String { "gauge.with.dots.needle.33percent" }
    override var actions: [NSView] { [toggleButton] }

    struct Item: Sendable {
        enum Kind: String, Sendable { case loginItem = "Login item", agent = "Launch agent", sharedAgent = "Launch agent (all users)", daemon = "Launch daemon" }
        let name: String
        let kind: Kind
        let location: String     // the app, or the launchd plist
        let program: String
        let label: String
        var enabled: Bool
        var publisher = ""
        var running = false
    }

    private static let disabledLoginItemsKey = "taskManagerDisabledLoginItems"

    private let table = TMTableView()
    private lazy var toggleButton = TMUI.button("Disable", symbol: "nosign", target: self, action: #selector(toggleSelected))
    private var items: [Item] = []
    private var rows: [Item] = []
    private var filter = ""
    private var loading = false

    override init() {
        super.init()
        for column in [
            TMUI.column("name", "Name", width: 260),
            TMUI.column("publisher", "Publisher", width: 170),
            TMUI.column("status", "Status", width: 90),
            TMUI.column("kind", "Type", width: 170),
            TMUI.column("location", "Location", width: 420),
        ] { table.addTableColumn(column) }
        TMUI.makeHeader(for: table, tall: false)
        table.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        table.rowHeight = 24
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.autosaveName = "WinSwitchTaskManagerStartup"
        table.autosaveTableColumns = true
        table.dataSource = self
        table.delegate = self
        table.menuForRow = { [weak self] row in self?.menu(for: row) }
        let scroll = TMUI.scroll(table)
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        toggleButton.isEnabled = false
    }

    override func didAppear() { load() }

    override func filterChanged(_ text: String) {
        filter = text.trimmingCharacters(in: .whitespaces).lowercased()
        applyFilter()
    }

    override func update(_ snapshot: SystemSnapshot) {}

    private func load() {
        guard !loading else { return }
        loading = true
        let disabledLogin = UserDefaults.standard.stringArray(forKey: Self.disabledLoginItemsKey) ?? []
        // launchd jobs first: login items go through System Events, which may wait for the Automation prompt.
        Task.detached(priority: .userInitiated) {
            let jobs = Self.withPublishers(Self.launchdJobs())
            await MainActor.run {
                self.items = jobs + self.items.filter { $0.kind == .loginItem }
                self.applyFilter()
            }
            let logins = Self.withPublishers(Self.loginItems(disabled: disabledLogin))
            await MainActor.run {
                self.loading = false
                self.items = logins + jobs
                self.applyFilter()
            }
        }
    }

    /// Login items (System Settings > General > Login Items > Open at Login).
    nonisolated private static func loginItems(disabled disabledLoginItems: [String]) -> [Item] {
        var result: [Item] = []
        let script = """
        set out to ""
        tell application "System Events"
            repeat with i in login items
                set out to out & (path of i) & linefeed
            end repeat
        end tell
        return out
        """
        let enabledPaths = Shell.run("/usr/bin/osascript", ["-e", script]).output
            .split(separator: "\n").map(String.init).filter { $0.hasPrefix("/") }
        for path in enabledPaths + disabledLoginItems.filter({ !enabledPaths.contains($0) }) {
            let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            result.append(Item(name: name, kind: .loginItem, location: path, program: path, label: name,
                               enabled: enabledPaths.contains(path)))
        }
        return result
    }

    nonisolated private static func launchdJobs() -> [Item] {
        var result: [Item] = []
        let uid = getuid()
        let guiDisabled = Shell.disabledLabels("gui/\(uid)")
        let systemDisabled = Shell.disabledLabels("system")
        let dirs: [(String, Item.Kind)] = [(NSHomeDirectory() + "/Library/LaunchAgents", .agent),
                                           ("/Library/LaunchAgents", .sharedAgent), ("/Library/LaunchDaemons", .daemon)]
        for (dir, kind) in dirs {
            for file in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where file.hasSuffix(".plist") {
                let path = dir + "/" + file
                guard let plist = NSDictionary(contentsOfFile: path) as? [String: Any], let label = plist["Label"] as? String else { continue }
                let program = plist["Program"] as? String ?? (plist["ProgramArguments"] as? [String])?.first ?? ""
                let overrides = kind == .daemon ? systemDisabled : guiDisabled
                let disabled = overrides[label] ?? (plist["Disabled"] as? Bool ?? false)
                let name = ProcessActions.bundlePath(of: program).map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension } ?? label
                result.append(Item(name: name == label ? label : "\(name) (\(label))", kind: kind, location: path, program: program,
                                   label: label, enabled: !disabled))
            }
        }
        return result
    }

    nonisolated private static func withPublishers(_ items: [Item]) -> [Item] {
        var result = items
        for i in result.indices {
            let target = ProcessActions.bundlePath(of: result[i].program) ?? result[i].program
            result[i].publisher = Shell.publisher(of: target)
        }
        return result
    }

    private func applyFilter() {
        var list = items
        if !filter.isEmpty {
            list = list.filter { $0.name.lowercased().contains(filter) || $0.publisher.lowercased().contains(filter) || $0.location.lowercased().contains(filter) }
        }
        let sort = table.sortDescriptors.first ?? NSSortDescriptor(key: "name", ascending: true)
        list.sort { a, b in
            let ordered: Bool
            switch sort.key {
            case "publisher": ordered = a.publisher.localizedStandardCompare(b.publisher) == .orderedAscending
            case "status": ordered = a.enabled && !b.enabled
            case "kind": ordered = a.kind.rawValue < b.kind.rawValue
            case "location": ordered = a.location < b.location
            default: ordered = a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            return sort.ascending ? ordered : !ordered
        }
        let selectedLocation = selected?.location
        rows = list
        table.reloadData()
        TMUI.updateHeaders(table, totals: [:])
        if let selectedLocation, let index = rows.firstIndex(where: { $0.location == selectedLocation }) {
            table.selectRowIndexes([index], byExtendingSelection: false)
        }
        updateButton()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier, row < rows.count else { return nil }
        let item = rows[row]
        if id.rawValue == "name" {
            let cell = tableView.makeView(withIdentifier: id, owner: nil) as? IconCell ?? IconCell(identifier: id)
            cell.label.stringValue = item.name
            cell.label.font = .systemFont(ofSize: 12)
            cell.icon.image = ProcessIcons.icon(for: item.program)
            return cell
        }
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? HeatCell ?? HeatCell(identifier: id, alignment: .left)
        cell.label.font = .systemFont(ofSize: 12)
        cell.label.textColor = .labelColor
        switch id.rawValue {
        case "publisher": cell.label.stringValue = item.publisher
        case "status":
            cell.label.stringValue = item.enabled ? "Enabled" : "Disabled"
            cell.label.textColor = item.enabled ? .labelColor : .secondaryLabelColor
        case "kind": cell.label.stringValue = item.kind.rawValue
        case "location": cell.label.stringValue = item.location
        default: break
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) { applyFilter() }
    func tableViewSelectionDidChange(_ notification: Notification) { updateButton() }

    private var selected: Item? { table.selectedRow >= 0 && table.selectedRow < rows.count ? rows[table.selectedRow] : nil }

    private func updateButton() {
        toggleButton.isEnabled = selected != nil
        toggleButton.title = selected?.enabled == false ? "Enable" : "Disable"
        toggleButton.image = NSImage(systemSymbolName: selected?.enabled == false ? "checkmark.circle" : "nosign", accessibilityDescription: nil)
    }

    /// Disabling only stops the item from starting next time, like Windows; it keeps running for now.
    @objc private func toggleSelected() {
        guard let item = selected else { return }
        let enable = !item.enabled
        let uid = getuid()
        switch item.kind {
        case .loginItem:
            var disabled = UserDefaults.standard.stringArray(forKey: Self.disabledLoginItemsKey) ?? []
            let escapedPath = item.location.replacingOccurrences(of: "\"", with: "\\\"")
            let escapedName = item.name.replacingOccurrences(of: "\"", with: "\\\"")
            let script = enable
                ? "tell application \"System Events\" to make login item at end with properties {path:\"\(escapedPath)\", hidden:false}"
                : "tell application \"System Events\" to delete login item \"\(escapedName)\""
            let result = Shell.run("/usr/bin/osascript", ["-e", script])
            guard result.status == 0 else { return showError(result.output) }
            if enable { disabled.removeAll { $0 == item.location } } else if !disabled.contains(item.location) { disabled.append(item.location) }
            UserDefaults.standard.set(disabled, forKey: Self.disabledLoginItemsKey)
        case .agent, .sharedAgent:
            let result = Shell.run("/bin/launchctl", [enable ? "enable" : "disable", "gui/\(uid)/\(item.label)"])
            guard result.status == 0 else { return showError(result.output) }
        case .daemon:
            guard ProcessActions.runAsAdministrator("/bin/launchctl \(enable ? "enable" : "disable") system/\(Shell.quote(item.label))") else { return }
        }
        load()
    }

    private func showError(_ text: String) {
        let alert = NSAlert()
        alert.messageText = "Couldn't change this startup item"
        alert.informativeText = text.isEmpty ? "Allow WinSwitch to control System Events in System Settings > Privacy & Security > Automation." : text
        alert.runModal()
    }

    @objc private func openFileLocation(_ sender: Any?) {
        guard let item = selected else { return }
        let url = URL(fileURLWithPath: item.location)
        Explorer.openWindow(at: url.deletingLastPathComponent(), select: url)
    }

    @objc private func searchOnline(_ sender: Any?) { ProcessActions.searchOnline(selected?.name ?? "") }

    private func menu(for row: Int) -> NSMenu? {
        guard row < rows.count else { return nil }
        let menu = NSMenu()
        menu.addItem(withTitle: rows[row].enabled ? "Disable" : "Enable", action: #selector(toggleSelected), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open file location", action: #selector(openFileLocation(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Search online", action: #selector(searchOnline(_:)), keyEquivalent: "").target = self
        return menu
    }
}

// MARK: - Services

@MainActor
final class ServicesPage: TMPage, NSTableViewDataSource, NSTableViewDelegate {
    override var title: String { "Services" }
    override var symbol: String { "gearshape.2" }
    override var actions: [NSView] { [startButton, stopButton, restartButton] }

    struct Service: Sendable {
        let label: String
        let pid: pid_t?
        let lastExit: String
        let system: Bool
        var domain: String { system ? "system" : "gui/\(getuid())" }
    }

    private let table = TMTableView()
    private lazy var startButton = TMUI.button("Start", symbol: "play", target: self, action: #selector(startService))
    private lazy var stopButton = TMUI.button("Stop", symbol: "stop", target: self, action: #selector(stopService))
    private lazy var restartButton = TMUI.button("Restart", symbol: "arrow.clockwise", target: self, action: #selector(restartService))
    private var services: [Service] = []
    private var rows: [Service] = []
    private var filter = ""
    private var loading = false
    private var lastLoad = Date.distantPast

    override init() {
        super.init()
        for column in [
            TMUI.column("label", "Name", width: 380),
            TMUI.column("pid", "PID", width: 70, right: true),
            TMUI.column("status", "Status", width: 90),
            TMUI.column("exit", "Last exit code", width: 100, right: true),
            TMUI.column("group", "Group", width: 90),
        ] { table.addTableColumn(column) }
        TMUI.makeHeader(for: table, tall: false)
        table.sortDescriptors = [NSSortDescriptor(key: "label", ascending: true)]
        table.rowHeight = 22
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.autosaveName = "WinSwitchTaskManagerServices"
        table.autosaveTableColumns = true
        table.dataSource = self
        table.delegate = self
        table.menuForRow = { [weak self] row in self?.menu(for: row) }
        let scroll = TMUI.scroll(table)
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        updateButtons()
    }

    override func didAppear() { load() }

    override func filterChanged(_ text: String) {
        filter = text.trimmingCharacters(in: .whitespaces).lowercased()
        applyFilter()
    }

    /// launchctl is slower than the process sample, so the list refreshes every 5 seconds.
    override func update(_ snapshot: SystemSnapshot) {
        if Date().timeIntervalSince(lastLoad) > 5 { load() }
    }

    private func load() {
        guard !loading else { return }
        loading = true
        lastLoad = Date()
        Task.detached(priority: .userInitiated) {
            let found = Self.discover()
            await MainActor.run {
                self.loading = false
                self.services = found
                self.applyFilter()
            }
        }
    }

    nonisolated private static func discover() -> [Service] {
        var result: [Service] = []
        // User services: "PID  Status  Label".
        for line in Shell.run("/bin/launchctl", ["list"]).output.split(separator: "\n").dropFirst() {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            // Running apps show up as "application.<bundle id>.<numbers>"; they belong on the Processes page.
            guard parts.count >= 3, !parts[2].hasPrefix("application.") else { continue }
            result.append(Service(label: String(parts[2]), pid: pid_t(parts[0]), lastExit: String(parts[1]), system: false))
        }
        // System services, from the services block of `launchctl print system`: "pid  exit  label".
        var inServices = false
        for line in Shell.run("/bin/launchctl", ["print", "system"]).output.split(separator: "\n") {
            if line.hasPrefix("\tservices = {") { inServices = true; continue }
            guard inServices else { continue }
            if line.hasPrefix("\t}") { break }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 3 else { continue }
            let pid = pid_t(parts[0]).flatMap { $0 > 0 ? $0 : nil }
            result.append(Service(label: parts[2...].joined(separator: " "), pid: pid, lastExit: String(parts[1]), system: true))
        }
        return result
    }

    private func applyFilter() {
        var list = services
        if !filter.isEmpty { list = list.filter { $0.label.lowercased().contains(filter) || $0.pid.map(String.init) == filter } }
        let sort = table.sortDescriptors.first ?? NSSortDescriptor(key: "label", ascending: true)
        list.sort { a, b in
            let ordered: Bool
            switch sort.key {
            case "pid": ordered = (a.pid ?? 0) < (b.pid ?? 0)
            case "status": ordered = (a.pid != nil) && b.pid == nil
            case "exit": ordered = a.lastExit < b.lastExit
            case "group": ordered = a.system == b.system ? a.label < b.label : !a.system
            default: ordered = a.label.localizedStandardCompare(b.label) == .orderedAscending
            }
            return sort.ascending ? ordered : !ordered
        }
        let selectedKey = selected.map { $0.domain + $0.label }
        rows = list
        table.reloadData()
        TMUI.updateHeaders(table, totals: [:])
        if let selectedKey, let index = rows.firstIndex(where: { $0.domain + $0.label == selectedKey }) {
            table.selectRowIndexes([index], byExtendingSelection: false)
        }
        updateButtons()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier, row < rows.count else { return nil }
        let s = rows[row]
        let right = id.rawValue == "pid" || id.rawValue == "exit"
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? HeatCell ?? HeatCell(identifier: id, alignment: right ? .right : .left)
        cell.label.font = .systemFont(ofSize: 12)
        cell.label.textColor = .labelColor
        switch id.rawValue {
        case "label": cell.label.stringValue = s.label
        case "pid": cell.label.stringValue = s.pid.map(String.init) ?? ""
        case "status":
            cell.label.stringValue = s.pid != nil ? "Running" : "Stopped"
            cell.label.textColor = s.pid != nil ? .labelColor : .secondaryLabelColor
        case "exit": cell.label.stringValue = s.lastExit == "-" ? "" : s.lastExit
        case "group": cell.label.stringValue = s.system ? "System" : "User"
        default: break
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) { applyFilter() }
    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    private var selected: Service? { table.selectedRow >= 0 && table.selectedRow < rows.count ? rows[table.selectedRow] : nil }

    private func updateButtons() {
        let s = selected
        startButton.isEnabled = s != nil && s?.pid == nil
        stopButton.isEnabled = s?.pid != nil
        restartButton.isEnabled = s != nil
    }

    private func launchctl(_ arguments: [String], for service: Service) {
        if service.system {
            ProcessActions.runAsAdministrator((["/bin/launchctl"] + arguments.map(Shell.quote)).joined(separator: " "))
        } else {
            let result = Shell.run("/bin/launchctl", arguments)
            if result.status != 0 {
                let alert = NSAlert()
                alert.messageText = "Couldn't change \(service.label)"
                alert.informativeText = result.output
                alert.runModal()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.load() }
    }

    @objc private func startService() {
        guard let s = selected else { return }
        launchctl(["kickstart", "\(s.domain)/\(s.label)"], for: s)
    }

    @objc private func stopService() {
        guard let s = selected else { return }
        launchctl(["kill", "SIGTERM", "\(s.domain)/\(s.label)"], for: s)
    }

    @objc private func restartService() {
        guard let s = selected else { return }
        launchctl(["kickstart", "-k", "\(s.domain)/\(s.label)"], for: s)
    }

    @objc private func goToDetails(_ sender: Any?) {
        guard let pid = selected?.pid else { return }
        manager?.showPage(DetailsPage.self)?.select(pid: pid)
    }

    @objc private func searchOnline(_ sender: Any?) { ProcessActions.searchOnline(selected?.label ?? "") }

    private func menu(for row: Int) -> NSMenu? {
        guard row < rows.count else { return nil }
        let s = rows[row]
        let menu = NSMenu()
        let start = menu.addItem(withTitle: "Start", action: #selector(startService), keyEquivalent: "")
        start.target = self
        start.isEnabled = s.pid == nil
        let stop = menu.addItem(withTitle: "Stop", action: #selector(stopService), keyEquivalent: "")
        stop.target = self
        stop.isEnabled = s.pid != nil
        menu.addItem(withTitle: "Restart", action: #selector(restartService), keyEquivalent: "").target = self
        menu.addItem(.separator())
        if s.pid != nil { menu.addItem(withTitle: "Go to details", action: #selector(goToDetails(_:)), keyEquivalent: "").target = self }
        menu.addItem(withTitle: "Search online", action: #selector(searchOnline(_:)), keyEquivalent: "").target = self
        menu.autoenablesItems = false
        return menu
    }
}
