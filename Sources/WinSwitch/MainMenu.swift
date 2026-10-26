import AppKit

/// The menu bar shown while an Explorer window is in front. Besides the menus themselves it is what makes
/// Cmd shortcuts work (Ctrl+C, V, X, A, N, T, W, F, L on the Windows keyboard, through the Remapper).
@MainActor
enum MainMenu {
    static func install() {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About WinSwitch", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide WinSwitch", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit WinSwitch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        add(appMenu, title: "WinSwitch", to: main)

        let file = NSMenu(title: "File")
        file.addItem(withTitle: "New Window", action: #selector(Explorer.newExplorerWindow(_:)), keyEquivalent: "n")
        file.addItem(withTitle: "New Tab", action: #selector(NSResponder.newWindowForTab(_:)), keyEquivalent: "t")
        item(file, "New Folder", #selector(Explorer.newFolder(_:)), "n", [.command, .shift])
        item(file, "Share...", #selector(Explorer.share(_:)), "", [])
        item(file, "Properties", #selector(Explorer.showProperties(_:)), "\r", [.option])
        file.addItem(.separator())
        file.addItem(withTitle: "Open", action: #selector(Explorer.openSelected), keyEquivalent: "")
        file.addItem(withTitle: "Open in Terminal", action: #selector(Explorer.openTerminalHere(_:)), keyEquivalent: "")
        file.addItem(withTitle: "Show in Finder", action: #selector(Explorer.showInFinder(_:)), keyEquivalent: "")
        file.addItem(.separator())
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        add(file, title: "File", to: main)

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        item(edit, "Redo", Selector(("redo:")), "z", [.command, .shift])
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        item(edit, "Copy as Path", #selector(Explorer.copyPath(_:)), "c", [.command, .option])
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Rename", action: #selector(Explorer.renameSelected(_:)), keyEquivalent: "")
        item(edit, "Delete", #selector(Explorer.deleteSelected(_:)), "\u{8}", [.command])
        edit.addItem(.separator())
        edit.addItem(withTitle: "Search", action: #selector(Explorer.focusSearch(_:)), keyEquivalent: "f")
        add(edit, title: "Edit", to: main)

        let view = NSMenu(title: "View")
        item(view, "Show Hidden Files", #selector(Explorer.toggleHidden(_:)), ".", [.command, .shift])
        view.addItem(withTitle: "Refresh", action: #selector(Explorer.refresh), keyEquivalent: "r")
        add(view, title: "View", to: main)

        let go = NSMenu(title: "Go")
        go.addItem(withTitle: "Back", action: #selector(Explorer.goBack), keyEquivalent: "[")
        go.addItem(withTitle: "Forward", action: #selector(Explorer.goForward), keyEquivalent: "]")
        item(go, "Up", #selector(Explorer.goUp), String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)), [.command])
        go.addItem(withTitle: "Address Bar", action: #selector(Explorer.focusAddress(_:)), keyEquivalent: "l")
        add(go, title: "Go", to: main)

        // Task Manager menus; their items only light up while the Task Manager is in front.
        file.insertItem(withTitle: "Run new task", action: #selector(TaskManager.runNewTask(_:)), keyEquivalent: "", at: 0)
        let options = NSMenu(title: "Options")
        options.addItem(withTitle: "Always on top", action: #selector(TaskManager.toggleAlwaysOnTop(_:)), keyEquivalent: "")
        let speed = NSMenuItem(title: "Real time update speed", action: nil, keyEquivalent: "")
        let speedMenu = NSMenu()
        for option in TaskManager.Speed.allCases {
            let item = NSMenuItem(title: option.title, action: #selector(TaskManager.setUpdateSpeed(_:)), keyEquivalent: "")
            item.representedObject = option.rawValue
            speedMenu.addItem(item)
        }
        speed.submenu = speedMenu
        options.addItem(speed)
        add(options, title: "Options", to: main)

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        add(window, title: "Window", to: main)
        NSApp.windowsMenu = window

        NSApp.mainMenu = main
    }

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
}
