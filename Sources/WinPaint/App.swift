import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static var shared: AppDelegate { NSApp.delegate as! AppDelegate }

    private var controllers: [PaintWindowController] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = PaintMenus.mainMenu(recentDelegate: self)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if controllers.isEmpty { newWindow() }
        if CommandLine.arguments.contains("--debug-demo") { controllers.first?.canvas.runDemo() }
        NSApp.activate()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { open(url) }
    }

    /// Opens a file in the front window if it is still untitled and blank, else in a new window.
    func open(_ url: URL) {
        let front = (NSApp.keyWindow?.windowController as? PaintWindowController) ?? controllers.last
        let target = front?.isPristine == true ? front! : newWindow()
        target.load(url)
        target.window?.makeKeyAndOrderFront(nil)
    }

    @discardableResult func newWindow() -> PaintWindowController {
        let controller = PaintWindowController()
        if let last = controllers.last?.window, let window = controller.window {
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: last.frame.minX, y: last.frame.maxY)))
        }
        controllers.append(controller)
        controller.showWindow(nil)
        return controller
    }

    func windowClosed(_ controller: PaintWindowController) {
        controllers.removeAll { $0 === controller }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        for controller in controllers where !controller.confirmDiscard() { return .terminateCancel }
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { newWindow() }
        return true
    }

    // MARK: Recent

    var recentFiles: [URL] {
        (UserDefaults.standard.stringArray(forKey: "RecentFiles") ?? []).map { URL(fileURLWithPath: $0) }
    }

    func noteRecent(_ url: URL) {
        var paths = recentFiles.map(\.path).filter { $0 != url.path }
        paths.insert(url.path, at: 0)
        UserDefaults.standard.set(Array(paths.prefix(10)), forKey: "RecentFiles")
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    func clearRecent() {
        UserDefaults.standard.removeObject(forKey: "RecentFiles")
        NSDocumentController.shared.clearRecentDocuments(nil)
    }

    func menuNeedsUpdate(_ menu: NSMenu) { PaintMenus.fillRecent(menu) }

    @objc func newWindowAction(_ sender: Any?) { newWindow() }
}

/// The menus, shared by the menu bar and the File / Edit / View buttons of the ribbon.
@MainActor
enum PaintMenus {
    private static func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command,
                             tag: Int = 0, hidden: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = mods
        item.tag = tag
        if hidden {
            item.isHidden = true
            item.allowsKeyEquivalentWhenHidden = true
        }
        return item
    }

    private static func functionKey(_ code: Int) -> String { String(Character(UnicodeScalar(code)!)) }

    private static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        parent.submenu = menu
        return parent
    }

    static func mainMenu(recentDelegate: NSMenuDelegate) -> NSMenu {
        let main = NSMenu()
        let app = NSMenu()
        app.addItem(item("About MS Paint", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""))
        app.addItem(.separator())
        let services = NSMenu()
        let servicesItem = item("Services", nil)
        servicesItem.submenu = services
        NSApp.servicesMenu = services
        app.addItem(servicesItem)
        app.addItem(.separator())
        app.addItem(item("Hide MS Paint", #selector(NSApplication.hide(_:)), "h"))
        app.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        app.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        app.addItem(.separator())
        app.addItem(item("Quit MS Paint", #selector(NSApplication.terminate(_:)), "q"))
        let appItem = NSMenuItem()
        appItem.submenu = app
        main.addItem(appItem)

        for menu in [file(false), edit(false), image(), view(false)] {
            let holder = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
            holder.submenu = menu
            main.addItem(holder)
        }
        if let recent = main.item(withTitle: "File")?.submenu?.item(withTitle: "Recent")?.submenu {
            recent.delegate = recentDelegate
        }

        let window = NSMenu(title: "Window")
        window.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        window.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        window.addItem(.separator())
        window.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        windowItem.submenu = window
        main.addItem(windowItem)
        NSApp.windowsMenu = window
        return main
    }

    static func file(_ forRibbon: Bool) -> NSMenu {
        let menu = NSMenu(title: "File")
        menu.addItem(item("New", #selector(PaintWindowController.newDocument(_:)), "n"))
        menu.addItem(item("Open…", #selector(PaintWindowController.openDocument(_:)), "o"))
        let recent = submenu("Recent", [])
        if forRibbon { fillRecent(recent.submenu!) }
        menu.addItem(recent)
        menu.addItem(.separator())
        menu.addItem(item("Save", #selector(PaintWindowController.saveDocument(_:)), "s"))
        var formats = ImageFormat.allCases.map { item($0.menuTitle, #selector(PaintWindowController.saveAsFormat(_:)), tag: $0.rawValue) }
        formats.append(.separator())
        formats.append(item("Other format…", #selector(PaintWindowController.saveDocumentAs(_:)), "s", [.command, .shift]))
        menu.addItem(submenu("Save as", formats))
        menu.addItem(item("Save as (F12)", #selector(PaintWindowController.saveDocumentAs(_:)), functionKey(NSF12FunctionKey), [], hidden: true))
        menu.addItem(.separator())
        menu.addItem(item("Print…", #selector(PaintWindowController.printImage(_:)), "p"))
        menu.addItem(item("Page setup…", #selector(PaintWindowController.pageSetup(_:)), "p", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(submenu("Set as desktop background", [
            item("Fill", #selector(PaintWindowController.setDesktopBackground(_:)), tag: 0),
            item("Tile", #selector(PaintWindowController.setDesktopBackground(_:)), tag: 1),
            item("Center", #selector(PaintWindowController.setDesktopBackground(_:)), tag: 2),
        ]))
        menu.addItem(item("Image properties", #selector(PaintWindowController.imageProperties(_:)), "e", .control))
        menu.addItem(item("Image properties", #selector(PaintWindowController.imageProperties(_:)), "e", .command, hidden: true))
        menu.addItem(.separator())
        menu.addItem(item("Close window", #selector(NSWindow.performClose(_:)), "w", hidden: !forRibbon))
        menu.addItem(item("Exit", #selector(NSApplication.terminate(_:)), forRibbon ? "q" : ""))
        return menu
    }

    static func fillRecent(_ menu: NSMenu) {
        menu.removeAllItems()
        let files = AppDelegate.shared.recentFiles
        if files.isEmpty {
            let none = item("No recent files", nil)
            none.isEnabled = false
            menu.addItem(none)
            return
        }
        for (i, url) in files.enumerated() {
            let entry = item("\(i + 1) \(url.lastPathComponent)", #selector(PaintWindowController.openRecent(_:)))
            entry.representedObject = url
            entry.toolTip = url.path
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Clear list") { AppDelegate.shared.clearRecent() })
    }

    static func edit(_ forRibbon: Bool) -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(item("Undo", #selector(CanvasView.undo(_:)), "z"))
        menu.addItem(item("Redo", #selector(CanvasView.redo(_:)), "y"))
        menu.addItem(item("Redo", #selector(CanvasView.redo(_:)), "z", [.command, .shift], hidden: true))
        menu.addItem(.separator())
        menu.addItem(item("Cut", #selector(CanvasView.cut(_:)), "x"))
        menu.addItem(item("Copy", #selector(CanvasView.copy(_:)), "c"))
        menu.addItem(item("Paste", #selector(CanvasView.paste(_:)), "v"))
        menu.addItem(item("Paste from…", #selector(PaintWindowController.pasteFrom(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Select all", #selector(CanvasView.selectAll(_:)), "a"))
        menu.addItem(item("Invert selection", #selector(PaintWindowController.invertSelection(_:))))
        menu.addItem(item("Delete", #selector(CanvasView.delete(_:))))
        menu.addItem(item("Transparent selection", #selector(PaintWindowController.toggleTransparentSelection(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Rectangle selection", #selector(PaintWindowController.rectangleSelection(_:))))
        menu.addItem(item("Free-form selection", #selector(PaintWindowController.freeFormSelection(_:))))
        return menu
    }

    static func image() -> NSMenu {
        let menu = NSMenu(title: "Image")
        menu.addItem(item("Crop", #selector(PaintWindowController.crop(_:)), "x", [.command, .shift]))
        menu.addItem(item("Resize and skew…", #selector(PaintWindowController.resizeAndSkew(_:)), "r", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Rotate right 90°", #selector(PaintWindowController.rotateRight(_:))))
        menu.addItem(item("Rotate left 90°", #selector(PaintWindowController.rotateLeft(_:))))
        menu.addItem(item("Rotate 180°", #selector(PaintWindowController.rotate180(_:))))
        menu.addItem(item("Flip vertical", #selector(PaintWindowController.flipVertical(_:))))
        menu.addItem(item("Flip horizontal", #selector(PaintWindowController.flipHorizontal(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Invert colors", #selector(PaintWindowController.invertColors(_:)), "i", [.control, .shift]))
        menu.addItem(item("Image properties", #selector(PaintWindowController.imageProperties(_:))))
        return menu
    }

    static func view(_ forRibbon: Bool) -> NSMenu {
        let menu = NSMenu(title: "View")
        menu.addItem(item("Zoom in", #selector(PaintWindowController.zoomInImage(_:)), "="))
        menu.addItem(item("Zoom in", #selector(PaintWindowController.zoomInImage(_:)), "+", hidden: true))
        menu.addItem(item("Zoom out", #selector(PaintWindowController.zoomOutImage(_:)), "-"))
        menu.addItem(item("100%", #selector(PaintWindowController.actualSize(_:)), "0"))
        menu.addItem(item("Fit to window", #selector(PaintWindowController.fitToWindow(_:)), "9"))
        menu.addItem(.separator())
        menu.addItem(item("Rulers", #selector(PaintWindowController.toggleRulers(_:)), "r"))
        menu.addItem(item("Gridlines", #selector(PaintWindowController.toggleGridlines(_:)), "g", .control))
        menu.addItem(item("Status bar", #selector(PaintWindowController.toggleStatusBar(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Full screen", #selector(NSWindow.toggleFullScreen(_:)), functionKey(NSF11FunctionKey), []))
        menu.addItem(item("Full screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control], hidden: true))
        return menu
    }
}
