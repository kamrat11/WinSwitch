import AppKit
import Scintilla

/// WinCode: a Notepad++-style code editor, built on Scintilla and Lexilla like Notepad++ itself.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var window: EditorWindow!
    private var pendingFiles: [URL] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = EditorWindow()
        if !Session.restore(window) && pendingFiles.isEmpty { window.addDocument() }
        let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") && !DebugLaunch.values.contains($0) }
        window.open(pendingFiles + args.map { URL(fileURLWithPath: $0) })
        pendingFiles = []
        if window.documents.isEmpty { window.addDocument() }
        window.showWindow(nil)
        NSApp.activate()
        DebugLaunch.run(window)
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveSession() }
        }
        // Follow light/dark changes when the theme is "system".
        DistributedNotificationCenter.default().addObserver(forName: .init("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard Preferences.theme == "system" else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self?.window.applyPreferencesToAll() }
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let window else { pendingFiles += urls; return }
        window.open(urls)
        window.showWindow(nil)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // With session restore on, unsaved work is kept for the next launch instead of asking, like Notepad++.
        if Preferences.restoreSession {
            saveSession()
            return .terminateNow
        }
        for doc in window.documents where doc.isModified {
            if !window.confirmClose(doc) { return .terminateCancel }
        }
        return .terminateNow
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window.showWindow(nil)
        return true
    }

    private func saveSession() {
        guard let window, Preferences.restoreSession else { return }
        Session.save(window)
    }

    @objc func about(_ sender: Any?) {
        let credits = NSAttributedString(string: "A Notepad++-style editor for macOS.\nEditing component: Scintilla and Lexilla by Neil Hodgson.",
                                         attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor])
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    @objc func openHomepage(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "https://github.com/kamrat11/WinSwitch")!)
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
