import AppKit

/// WinPad: a plain text editor that works and looks like the Windows 11 Notepad.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    static let shared = AppDelegate()

    let printInfo = NSPrintInfo.shared.copy() as! NSPrintInfo
    private var launched = false
    private var pendingURLs: [URL] = []
    private var settings: SettingsWindow?

    func applicationWillFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
        Preferences.applyTheme()
        MainMenu.install()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        launched = true
        let args = CommandLine.arguments
        if Preferences.restoreSession { Session.restore() }
        // Files passed on the command line (when run from a terminal rather than with `open`).
        let files = args.dropFirst().filter { $0.hasPrefix("/") && FileManager.default.fileExists(atPath: $0) }
        pendingURLs += files.map { URL(fileURLWithPath: $0) }
        if !pendingURLs.isEmpty { open(pendingURLs); pendingURLs = [] }
        if Editor.all.isEmpty { Editor.open() }

        // Hidden switches for checking UI states in screenshots.
        if let i = args.firstIndex(of: "--debug-show-find") {
            if args.indices.contains(i + 1), !args[i + 1].hasPrefix("-") { FindBar.lastSearch = args[i + 1] }
            Editor.front?.openFind(replace: args.contains("--debug-replace"))
            if !FindBar.lastSearch.isEmpty { Editor.front?.findNextMatch(nil) }
        }
        if args.contains("--debug-settings") { showSettings(nil) }
        NSApp.activate()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard launched else { pendingURLs += urls; return }
        open(urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if Preferences.restoreSession {
            Session.save()
            return .terminateNow
        }
        for editor in Editor.all where !editor.confirmClose() { return .terminateCancel }
        Session.clear()
        return .terminateNow
    }

    func applicationDidResignActive(_ notification: Notification) {
        // Keeps unsaved work safe if WinPad is killed rather than quit.
        if Preferences.restoreSession, !Editor.all.isEmpty { Session.save() }
    }

    // MARK: Opening files

    func open(_ urls: [URL]) {
        for url in urls {
            if let existing = Editor.all.first(where: { $0.url?.standardizedFileURL == url.standardizedFileURL }) {
                existing.window?.makeKeyAndOrderFront(nil)
                continue
            }
            let contents: TextFile.Contents
            do {
                contents = try TextFile.read(url)
            } catch {
                let alert = NSAlert(error: error)
                alert.messageText = "Notepad can't open \(url.lastPathComponent)"
                alert.runModal()
                continue
            }
            let editor: Editor
            if let front = Editor.front, front.isEmptyUntitled, (front.window?.tabbedWindows?.count ?? 1) == 1 {
                front.load(contents, url: url)
                editor = front
            } else {
                editor = Editor.open(contents, url: url, asTabOf: Editor.front?.window)
            }
            editor.window?.makeKeyAndOrderFront(nil)
            editor.appendLogStampIfNeeded()
            Preferences.noteRecent(url)
        }
        NSApp.activate()
    }

    // MARK: Actions that work without a window

    @objc func newDocument(_ sender: Any?) {
        Editor.open(asTabOf: Editor.front?.window)
    }

    @objc func newEditorWindow(_ sender: Any?) { Editor.open() }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.title = "Open"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if let url = Editor.front?.url { panel.directoryURL = url.deletingLastPathComponent() }
        guard panel.runModal() == .OK else { return }
        open(panel.urls)
    }

    @objc func openRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        open([url])
    }

    @objc func clearRecent(_ sender: Any?) {
        Preferences.recentFiles = []
        NSDocumentController.shared.clearRecentDocuments(nil)
    }

    @objc func saveAll(_ sender: Any?) {
        for editor in Editor.all where editor.isModified || editor.url == nil && !editor.text.isEmpty {
            guard editor.save() else { return }
        }
    }

    @objc func runPageLayout(_ sender: Any?) {
        NSPageLayout().runModal(with: printInfo)
    }

    @objc func showSettings(_ sender: Any?) {
        if settings == nil { settings = SettingsWindow() }
        settings?.showWindow(nil)
        settings?.window?.makeKeyAndOrderFront(nil)
    }

    @objc func toggleStatusBar(_ sender: Any?) { Preferences.statusBar.toggle() }
    @objc func toggleWordWrap(_ sender: Any?) { Preferences.wordWrap.toggle() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleStatusBar(_:)): item.state = Preferences.statusBar ? .on : .off
        case #selector(toggleWordWrap(_:)): item.state = Preferences.wordWrap ? .on : .off
        default: break
        }
        return true
    }

    /// Fills File > Recent each time it opens.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let recent = Preferences.recentFiles
        for url in recent {
            let item = menu.addItem(withTitle: url.lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
            item.representedObject = url
            item.toolTip = url.path
            item.target = self
        }
        if recent.isEmpty {
            menu.addItem(withTitle: "No recent files", action: nil, keyEquivalent: "").isEnabled = false
        } else {
            menu.addItem(.separator())
            menu.addItem(withTitle: "Clear recent", action: #selector(clearRecent(_:)), keyEquivalent: "").target = self
        }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.delegate = AppDelegate.shared
    app.setActivationPolicy(.regular)
    app.run()
}
