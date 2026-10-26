import AppKit

/// Notepad's menus with Windows wording. Ctrl shortcuts arrive as Cmd through WinSwitch, except Ctrl+H, Ctrl+G
/// and Ctrl+E, which arrive as Control and so are bound to Control here.
@MainActor
enum MainMenu {
    static func install() {
        let main = NSMenu()
        let app = AppDelegate.shared

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Notepad", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings...", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Notepad", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        item(appMenu, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Notepad", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        add(appMenu, title: "Notepad", to: main)

        let file = NSMenu(title: "File")
        file.addItem(withTitle: "New tab", action: #selector(AppDelegate.newDocument(_:)), keyEquivalent: "n")
        item(file, "New window", #selector(AppDelegate.newEditorWindow(_:)), "n", [.command, .shift])
        file.addItem(withTitle: "Open...", action: #selector(AppDelegate.openDocument(_:)), keyEquivalent: "o")
        let recent = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu(title: "Recent")
        recentMenu.delegate = app
        recent.submenu = recentMenu
        file.addItem(recent)
        file.addItem(withTitle: "Save", action: #selector(Editor.saveDocument(_:)), keyEquivalent: "s")
        item(file, "Save as...", #selector(Editor.saveDocumentAs(_:)), "s", [.command, .shift])
        item(file, "Save all", #selector(AppDelegate.saveAll(_:)), "s", [.command, .option])
        file.addItem(.separator())
        file.addItem(withTitle: "Page setup...", action: #selector(AppDelegate.runPageLayout(_:)), keyEquivalent: "")
        file.addItem(withTitle: "Print...", action: #selector(Editor.printText(_:)), keyEquivalent: "p")
        file.addItem(.separator())
        file.addItem(withTitle: "Close tab", action: #selector(Editor.closeTab(_:)), keyEquivalent: "w")
        item(file, "Close window", #selector(Editor.closeWindow(_:)), "w", [.command, .shift])
        file.addItem(withTitle: "Exit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        add(file, title: "File", to: main)

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        item(edit, "Redo", Selector(("redo:")), "z", [.command, .shift])
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        edit.addItem(.separator())
        item(edit, "Search with Google", #selector(Editor.searchWithGoogle(_:)), "e", [.control])
        item(edit, "Find...", #selector(Editor.showFind(_:)), "f", [.command])
        item(edit, "Find next", #selector(Editor.findNextMatch(_:)), fKey(NSF3FunctionKey), [])
        item(edit, "Find previous", #selector(Editor.findPreviousMatch(_:)), fKey(NSF3FunctionKey), [.shift])
        hidden(edit, #selector(Editor.findNextMatch(_:)), "g", [.command])
        hidden(edit, #selector(Editor.findPreviousMatch(_:)), "g", [.command, .shift])
        item(edit, "Replace...", #selector(Editor.showReplace(_:)), "h", [.control])
        hidden(edit, #selector(Editor.showReplace(_:)), "h", [.command, .option])
        item(edit, "Go to...", #selector(Editor.goToLine(_:)), "g", [.control])
        hidden(edit, #selector(Editor.goToLine(_:)), "g", [.command, .option])
        edit.addItem(.separator())
        edit.addItem(withTitle: "Select all", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        item(edit, "Time/Date", #selector(Editor.insertTimeDate(_:)), fKey(NSF5FunctionKey), [])
        edit.addItem(.separator())
        edit.addItem(withTitle: "Font...", action: #selector(Editor.showFonts(_:)), keyEquivalent: "")
        add(edit, title: "Edit", to: main)

        let view = NSMenu(title: "View")
        let zoom = NSMenuItem(title: "Zoom", action: nil, keyEquivalent: "")
        let zoomMenu = NSMenu(title: "Zoom")
        zoomMenu.addItem(withTitle: "Zoom in", action: #selector(Editor.zoomIn(_:)), keyEquivalent: "=")
        hidden(zoomMenu, #selector(Editor.zoomIn(_:)), "+", [.command])
        zoomMenu.addItem(withTitle: "Zoom out", action: #selector(Editor.zoomOut(_:)), keyEquivalent: "-")
        zoomMenu.addItem(withTitle: "Restore default zoom", action: #selector(Editor.resetZoom(_:)), keyEquivalent: "0")
        zoom.submenu = zoomMenu
        view.addItem(zoom)
        view.addItem(withTitle: "Status bar", action: #selector(AppDelegate.toggleStatusBar(_:)), keyEquivalent: "")
        view.addItem(withTitle: "Word wrap", action: #selector(AppDelegate.toggleWordWrap(_:)), keyEquivalent: "")
        add(view, title: "View", to: main)

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        add(window, title: "Window", to: main)
        NSApp.windowsMenu = window

        NSApp.mainMenu = main
    }

    private static func fKey(_ key: Int) -> String { String(Character(UnicodeScalar(UInt32(key))!)) }

    private static func add(_ menu: NSMenu, title: String, to main: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        main.addItem(item)
    }

    private static func item(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String, _ mods: NSEvent.ModifierFlags) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = mods
        menu.addItem(item)
    }

    /// An extra shortcut for an action, kept out of sight.
    private static func hidden(_ menu: NSMenu, _ action: Selector, _ key: String, _ mods: NSEvent.ModifierFlags) {
        let item = NSMenuItem(title: "", action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = mods
        item.isHidden = true
        item.allowsKeyEquivalentWhenHidden = true
        menu.addItem(item)
    }
}
