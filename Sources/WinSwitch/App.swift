import AppKit
import ServiceManagement

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    private var statusItem: NSStatusItem!
    private let switcher = Switcher()
    private lazy var keyboard = KeyboardTap(switcher: switcher)
    private let dockPreviews = DockPreviews()
    private var permissionTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "WinSwitch")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        keyboard.onToggleWindowsKeys = { [weak self] in self?.toggleWindowsKeys() }
        keyboard.remapper.onRun = { RunDialog.shared.show() }
        keyboard.remapper.onExplorer = { Explorer.openWindow() }
        keyboard.remapper.onClipboard = { ClipboardPanel.shared.toggle() }
        keyboard.remapper.onTaskManager = { TaskManager.show() }
        // Lets scripts open the panels: `notifyutil`-style distributed notifications, e.g. from a Shortcut.
        DistributedNotificationCenter.default().addObserver(forName: .init("com.kamrat.WinSwitch.showClipboard"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ClipboardPanel.shared.toggle() }
        }
        // Alt+Tab without holding Alt (for screenshots): showSwitcher opens it, hideSwitcher cancels it.
        DistributedNotificationCenter.default().addObserver(forName: .init("com.kamrat.WinSwitch.showSwitcher"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.switcher.open(reverse: false) }
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("com.kamrat.WinSwitch.hideSwitcher"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.switcher.cancel() }
        }
        // PrtSc / Alt+PrtSc without the keys: screenshotScreen and screenshotWindow.
        DistributedNotificationCenter.default().addObserver(forName: .init("com.kamrat.WinSwitch.screenshotScreen"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Screenshot.screenUnderMouse() }
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("com.kamrat.WinSwitch.screenshotWindow"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Screenshot.frontWindow() }
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("com.kamrat.WinSwitch.showTaskManager"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { TaskManager.show() }
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("com.kamrat.WinSwitch.toggleDesktop"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ShowDesktop.toggle() }
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("com.kamrat.WinSwitch.restoreDesktop"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ShowDesktop.restoreAll() }
        }
        HIDMonitor.shared.onWinAlone = { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Apps.app")) }
        MainMenu.install()

        // `WinSwitch --explorer [folder | "This PC"]` opens an Explorer window at launch, `--properties path` a
        // Properties window.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--explorer") {
            let path = args.indices.contains(i + 1) ? RunCommand.expand(args[i + 1]) : NSHomeDirectory()
            Explorer.openWindow(at: path.lowercased() == "this pc" ? Explorer.thisPC : URL(fileURLWithPath: path))
        }
        if let i = args.firstIndex(of: "--properties"), args.indices.contains(i + 1) {
            PropertiesWindow.show([URL(fileURLWithPath: RunCommand.expand(args[i + 1]))])
        }
        if args.contains("--task-manager") { TaskManager.show() }

        Permissions.requestAccessibility()
        Permissions.requestScreenRecording()
        startWhenTrusted()
    }

    /// The keyboard hook and Dock watcher need Accessibility; retry until it is granted.
    private func startWhenTrusted() {
        if Permissions.accessibilityGranted && keyboard.start() {
            dockPreviews.start()
            WindowHistory.shared.start()
            ClipboardHistory.shared.start()
            HIDMonitor.shared.start()
            watchInputMonitoring()
            permissionTimer?.invalidate()
            permissionTimer = nil
            return
        }
        guard permissionTimer == nil else { return }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.startWhenTrusted() }
        }
    }

    // MARK: Windows-style keys

    @objc private func toggleWindowsKeys() {
        Settings.windowsKeysEnabled.toggle()
        if Settings.windowsKeysEnabled {
            HUD.shared.show("Windows keys ON", symbol: "keyboard")
        } else {
            HUD.shared.show("Windows keys OFF (Mac keys)", symbol: "keyboard.badge.ellipsis")
        }
    }

    /// Win-key shortcuts need Input Monitoring; once it is granted the HID monitor has to be reopened.
    private func watchInputMonitoring() {
        guard !HIDMonitor.permissionGranted else { return }
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { timer in
            MainActor.assumeIsolated {
                guard HIDMonitor.permissionGranted else { return }
                timer.invalidate()
                HIDMonitor.shared.restart()
            }
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let keysOn = Settings.windowsKeysEnabled
        let keys = NSMenuItem(title: "Windows-style keys", action: #selector(toggleWindowsKeys), keyEquivalent: "k")
        keys.keyEquivalentModifierMask = [.control, .option, .command]
        keys.state = keysOn ? .on : .off
        keys.target = self
        menu.addItem(keys)

        let run = NSMenuItem(title: "Run… (Win+R)", action: #selector(showRun), keyEquivalent: "")
        run.target = self
        menu.addItem(run)

        let explorer = NSMenuItem(title: "File Explorer (Win+E)", action: #selector(showExplorer), keyEquivalent: "")
        explorer.target = self
        menu.addItem(explorer)

        let taskManager = NSMenuItem(title: "Task Manager (Ctrl+Shift+Esc)", action: #selector(showTaskManager), keyEquivalent: "")
        taskManager.target = self
        menu.addItem(taskManager)

        let showClipboard = NSMenuItem(title: "Clipboard history… (Win+V)", action: #selector(showClipboard), keyEquivalent: "")
        showClipboard.target = self
        menu.addItem(showClipboard)

        let clipboard = NSMenuItem(title: "Remember clipboard history", action: #selector(toggleClipboard), keyEquivalent: "")
        clipboard.state = Settings.clipboardHistoryEnabled ? .on : .off
        clipboard.target = self
        menu.addItem(clipboard)

        let switcherItem = NSMenuItem(title: "Alt+Tab window switcher", action: #selector(toggleSwitcher), keyEquivalent: "")
        switcherItem.state = Settings.switcherEnabled ? .on : .off
        switcherItem.target = self
        menu.addItem(switcherItem)

        let wheel = NSMenuItem(title: "Reverse mouse wheel (Windows direction)", action: #selector(toggleWheel), keyEquivalent: "")
        wheel.state = Settings.reverseMouseWheel ? .on : .off
        wheel.target = self
        menu.addItem(wheel)

        let dockItem = NSMenuItem(title: "Dock previews", action: nil, keyEquivalent: "")
        let dockMenu = NSMenu()
        for mode in Settings.DockActivation.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(setDockMode(_:)), keyEquivalent: "")
            item.representedObject = mode.rawValue
            item.state = Settings.dockActivation == mode ? .on : .off
            item.target = self
            dockMenu.addItem(item)
        }
        dockItem.submenu = dockMenu
        menu.addItem(dockItem)

        menu.addItem(.separator())

        if !Permissions.accessibilityGranted {
            let item = NSMenuItem(title: "Grant Accessibility permission…", action: #selector(openAccessibility), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        if !HIDMonitor.permissionGranted {
            let item = NSMenuItem(title: "Grant Input Monitoring (for Win-key shortcuts)…", action: #selector(openInputMonitoring), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        if !Permissions.screenRecordingGranted {
            let item = NSMenuItem(title: "Grant Screen Recording (for previews)…", action: #selector(openScreenRecording), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }

        if !Permissions.fullDiskAccessGranted {
            let item = NSMenuItem(title: "Grant Full Disk Access (for File Explorer)…", action: #selector(openFullDiskAccess), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }

        let login = NSMenuItem(title: "Start at login", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        login.target = self
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit WinSwitch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func showRun() { RunDialog.shared.show() }
    @objc private func showClipboard() { ClipboardPanel.shared.toggle() }
    @objc private func showExplorer() { Explorer.openWindow() }
    @objc private func showTaskManager() { TaskManager.show() }

    @objc private func toggleSwitcher() { Settings.switcherEnabled.toggle() }
    @objc private func toggleWheel() { Settings.reverseMouseWheel.toggle() }
    @objc private func toggleClipboard() {
        Settings.clipboardHistoryEnabled.toggle()
        if !Settings.clipboardHistoryEnabled { ClipboardHistory.shared.clearUnpinned() }
    }
    @objc private func openInputMonitoring() { Permissions.openSettings(.inputMonitoring) }

    @objc private func setDockMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = Settings.DockActivation(rawValue: raw) else { return }
        Settings.dockActivation = mode
        dockPreviews.hide()
    }

    @objc private func openAccessibility() { Permissions.openSettings(.accessibility) }
    @objc private func openScreenRecording() { Permissions.openSettings(.screenRecording) }
    @objc private func openFullDiskAccess() { Explorer.requestFullDiskAccess() }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            HUD.shared.show("Start at login failed", symbol: "exclamationmark.triangle")
            NSLog("WinSwitch: login item: \(error)")
        }
    }
}
