import AppKit

/// A page of the Task Manager (Processes, Performance, Details...).
@MainActor
class TMPage: NSObject {
    let view = NSView()
    var title: String { "" }
    var symbol: String { "" }
    var searchable: Bool { true }
    /// Buttons shown on the right of the page header.
    var actions: [NSView] { [] }
    weak var manager: TaskManager?

    func update(_ snapshot: SystemSnapshot) {}
    func filterChanged(_ text: String) {}
    /// Called when the page is shown, e.g. to load data that isn't sampled every tick.
    func didAppear() {}
    @objc func endTask(_ sender: Any?) {}
}

/// Windows-style Task Manager (Ctrl+Shift+Esc): processes, performance graphs, startup apps, users, details, services.
@MainActor
final class TaskManager: NSWindowController, NSWindowDelegate, NSMenuItemValidation, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private static var shared: TaskManager?
    static var isOpen: Bool { shared?.window?.isVisible == true }

    /// Ctrl+Shift+Esc: opens the Task Manager, or brings it to the front.
    static func show() {
        let manager = shared ?? TaskManager()
        shared = manager
        NSApp.setActivationPolicy(.regular) // in the Dock and Alt+Tab while it is open, like Explorer
        manager.showWindow(nil)
        if let window = manager.window { Windows.focusOwn(window) }
        manager.start()
    }

    enum Speed: String, CaseIterable {
        case high, normal, low, paused
        var title: String { ["High", "Normal", "Low", "Paused"][Self.allCases.firstIndex(of: self)!] }
        var interval: TimeInterval? { [0.5, 1, 4, nil][Self.allCases.firstIndex(of: self)!] }
    }

    static var speed: Speed {
        get { Speed(rawValue: UserDefaults.standard.string(forKey: "taskManagerSpeed") ?? "") ?? .normal }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "taskManagerSpeed") }
    }

    static var alwaysOnTop: Bool {
        get { UserDefaults.standard.bool(forKey: "taskManagerOnTop") }
        set { UserDefaults.standard.set(newValue, forKey: "taskManagerOnTop") }
    }

    // MARK: State

    private let sampler = SystemSampler()
    private let queue = DispatchQueue(label: "com.kamrat.WinSwitch.taskmanager", qos: .userInitiated)
    private var timer: Timer?
    private var sampling = false
    private(set) var snapshot = SystemSnapshot()

    private lazy var pages: [TMPage] = [ProcessesPage(), PerformancePage(), StartupPage(), UsersPage(), DetailsPage(),
                                        ServicesPage(), TMSettingsPage()]
    private var current: TMPage?

    private let nav = NSTableView()
    private let titleLabel = TMUI.label("", size: 15, weight: .semibold)
    private let actionStack = NSStackView()
    let searchField = NSSearchField()
    private let pageContainer = NSView()
    private let statusLabel = TMUI.label("", size: 11, secondary: true)

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Task Manager"
        window.minSize = NSSize(width: 720, height: 440)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("WinSwitchTaskManager")
        if !window.setFrameUsingName("WinSwitchTaskManager") { window.center() }
        super.init(window: window)
        window.delegate = self
        window.level = Self.alwaysOnTop ? .floating : .normal
        for page in pages { page.manager = self }
        buildUI()
        let start = UserDefaults.standard.integer(forKey: "taskManagerPage")
        select(page: pages.indices.contains(start) ? start : 0)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Layout

    private func buildUI() {
        guard let content = window?.contentView else { return }

        // Navigation rail on the left, as in Windows 11.
        let navColumn = NSTableColumn(identifier: .init("nav"))
        nav.addTableColumn(navColumn)
        nav.headerView = nil
        nav.style = .sourceList
        nav.rowHeight = 30
        nav.dataSource = self
        nav.delegate = self
        nav.backgroundColor = .clear
        let navScroll = TMUI.scroll(nav)
        navScroll.hasHorizontalScroller = false
        navScroll.drawsBackground = false

        let sidebar = NSVisualEffectView()
        sidebar.material = .sidebar
        sidebar.blendingMode = .behindWindow
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(navScroll)

        searchField.placeholderString = "Type a name, publisher, or PID to search"
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.translatesAutoresizingMaskIntoConstraints = false

        actionStack.orientation = .horizontal
        actionStack.spacing = 8
        let header = NSStackView(views: [titleLabel, NSView(), searchField, actionStack])
        header.orientation = .horizontal
        header.spacing = 12
        header.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 14)
        header.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        pageContainer.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        for view in [sidebar, header, separator, pageContainer, statusLabel] { content.addSubview(view) }
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: content.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 180),
            navScroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            navScroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            navScroll.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 8),
            navScroll.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),

            header.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            header.topAnchor.constraint(equalTo: content.topAnchor),
            header.heightAnchor.constraint(equalToConstant: 50),
            searchField.widthAnchor.constraint(equalToConstant: 320),

            separator.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            separator.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            separator.topAnchor.constraint(equalTo: header.bottomAnchor),

            pageContainer.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            pageContainer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            pageContainer.topAnchor.constraint(equalTo: separator.bottomAnchor),
            pageContainer.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -4),

            statusLabel.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            statusLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -5),
        ])
    }

    func select(page index: Int) {
        let page = pages[index]
        if page === current { return }
        current?.view.removeFromSuperview()
        current = page
        UserDefaults.standard.set(index, forKey: "taskManagerPage")
        if nav.selectedRow != index { nav.selectRowIndexes([index], byExtendingSelection: false) }

        page.view.translatesAutoresizingMaskIntoConstraints = false
        pageContainer.addSubview(page.view)
        NSLayoutConstraint.activate([
            page.view.leadingAnchor.constraint(equalTo: pageContainer.leadingAnchor),
            page.view.trailingAnchor.constraint(equalTo: pageContainer.trailingAnchor),
            page.view.topAnchor.constraint(equalTo: pageContainer.topAnchor),
            page.view.bottomAnchor.constraint(equalTo: pageContainer.bottomAnchor),
        ])
        titleLabel.stringValue = page.title
        actionStack.setViews(page.actions, in: .leading)
        searchField.isHidden = !page.searchable
        page.filterChanged(searchField.stringValue)
        page.didAppear()
        page.update(snapshot)
    }

    // MARK: Sampling

    private func start() {
        timer?.invalidate()
        timer = nil
        if snapshot.processes.isEmpty {
            // Two quick samples so the first rates (CPU, disk) are real numbers.
            tick()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.tick() }
        }
        guard let interval = Self.speed.interval else { return }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard !sampling else { return }
        sampling = true
        let sampler = self.sampler
        queue.async { [weak self] in
            let snapshot = sampler.sample()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.sampling = false
                    self.snapshot = snapshot
                    for page in self.pages { (page as? PerformancePage)?.record(snapshot) }
                    self.current?.update(snapshot)
                    self.statusLabel.stringValue = "Processes: \(snapshot.processes.count)    CPU usage: \(Format.percent(snapshot.cpuTotal, decimals: 0))    Physical memory: \(Format.percent(snapshot.memory.usedFraction, decimals: 0))    Update speed: \(Self.speed.title)"
                }
            }
        }
    }

    func speedChanged() {
        start()
        tick()
    }

    // MARK: Actions (also reached through the menu bar)

    @objc func refresh() { tick(); current?.didAppear() }
    @objc func focusSearch(_ sender: Any?) {
        guard current?.searchable == true else { return }
        window?.makeFirstResponder(searchField)
    }
    @objc func runNewTask(_ sender: Any?) { RunDialog.shared.show() }
    @objc func toggleAlwaysOnTop(_ sender: Any?) {
        Self.alwaysOnTop.toggle()
        window?.level = Self.alwaysOnTop ? .floating : .normal
    }
    @objc func setUpdateSpeed(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let speed = Speed(rawValue: raw) else { return }
        Self.speed = speed
        speedChanged()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleAlwaysOnTop(_:)) { item.state = Self.alwaysOnTop ? .on : .off }
        if item.action == #selector(setUpdateSpeed(_:)) { item.state = item.representedObject as? String == Self.speed.rawValue ? .on : .off }
        return true
    }

    func controlTextDidChange(_ obj: Notification) {
        current?.filterChanged(searchField.stringValue)
        current?.update(snapshot)
    }

    func showPage<T: TMPage>(_ type: T.Type) -> T? {
        guard let index = pages.firstIndex(where: { $0 is T }) else { return nil }
        select(page: index)
        return pages[index] as? T
    }

    // MARK: Window

    func windowDidMiniaturize(_ notification: Notification) { stop() }
    func windowDidDeminiaturize(_ notification: Notification) { start() }

    func windowWillClose(_ notification: Notification) {
        stop()
        // Keep the object (and its history) for the next Ctrl+Shift+Esc, but drop back to a menu bar app.
        DispatchQueue.main.async {
            if !Explorer.hasOpenWindows { NSApp.setActivationPolicy(.accessory) }
        }
    }

    // MARK: Navigation rail

    func numberOfRows(in tableView: NSTableView) -> Int { pages.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: .init("navCell"), owner: nil) as? IconCell ?? IconCell(identifier: .init("navCell"))
        cell.label.stringValue = pages[row].title
        cell.label.font = .systemFont(ofSize: 13)
        cell.icon.image = NSImage(systemSymbolName: pages[row].symbol, accessibilityDescription: nil)
        cell.icon.contentTintColor = .secondaryLabelColor
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard nav.selectedRow >= 0 else { return }
        select(page: nav.selectedRow)
    }
}

// MARK: - Settings page

@MainActor
final class TMSettingsPage: TMPage {
    override var title: String { "Settings" }
    override var symbol: String { "gearshape" }
    override var searchable: Bool { false }

    private let speedPopup = NSPopUpButton()
    private let onTop = NSButton(checkboxWithTitle: "Always on top", target: nil, action: nil)

    override init() {
        super.init()
        for speed in TaskManager.Speed.allCases { speedPopup.addItem(withTitle: speed.title) }
        speedPopup.target = self
        speedPopup.action = #selector(speedChanged)
        onTop.target = self
        onTop.action = #selector(onTopChanged)

        let grid = NSGridView(views: [
            [TMUI.label("Real time update speed"), speedPopup],
            [TMUI.label("Window management"), onTop],
            [NSView(), TMUI.label("Ctrl+Shift+Esc opens the Task Manager from anywhere. Type taskmgr in the Run box (Win+R) to open it too.", size: 11, secondary: true)],
        ])
        grid.rowSpacing = 14
        grid.columnSpacing = 18
        grid.column(at: 0).xPlacement = .trailing
        grid.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            grid.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -28),
        ])
    }

    override func didAppear() {
        speedPopup.selectItem(at: TaskManager.Speed.allCases.firstIndex(of: TaskManager.speed) ?? 1)
        onTop.state = TaskManager.alwaysOnTop ? .on : .off
    }

    @objc private func speedChanged() {
        TaskManager.speed = TaskManager.Speed.allCases[speedPopup.indexOfSelectedItem]
        manager?.speedChanged()
    }

    @objc private func onTopChanged() { manager?.toggleAlwaysOnTop(nil) }
}
