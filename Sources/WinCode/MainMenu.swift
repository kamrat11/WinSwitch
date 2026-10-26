import AppKit

/// Notepad++'s menu bar. Shortcuts are given as they arrive from a Windows keyboard through WinSwitch:
/// Ctrl+A C D F K L N O P R S T V W X Z = - 0 become Cmd, other Ctrl letters stay Control, F keys arrive as F keys.
@MainActor
enum MainMenu {
    private static func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = [.command],
                             tag: Int = 0, object: Any? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : mods
        item.tag = tag
        item.representedObject = object
        return item
    }

    private static func fn(_ n: Int) -> String { String(UnicodeScalar(NSF1FunctionKey + n - 1)!) }
    private static let up = String(UnicodeScalar(NSUpArrowFunctionKey)!)
    private static let down = String(UnicodeScalar(NSDownArrowFunctionKey)!)

    private static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        item.submenu = menu
        return item
    }

    static func build() -> NSMenu {
        let main = NSMenu()
        let w = EditorWindow.self

        main.addItem(submenu("Notepad++", [
            item("About Notepad++", #selector(AppDelegate.about(_:))),
            .separator(),
            item("Preferences...", #selector(w.showPreferences(_:)), ","),
            .separator(),
            item("Hide Notepad++", #selector(NSApplication.hide(_:)), "h", [.command]),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Quit Notepad++", #selector(NSApplication.terminate(_:)), "q"),
        ]))

        let recent = submenu("Recent Files", [])
        recent.submenu?.delegate = RecentMenu.shared
        main.addItem(submenu("File", [
            item("New", #selector(w.newDocument(_:)), "n"),
            item("Open...", #selector(w.openDocument(_:)), "o"),
            submenu("Open Containing Folder", [
                item("Finder", #selector(w.revealInFinder(_:))),
                item("Terminal", #selector(w.openInTerminal(_:))),
            ]),
            item("Reload from Disk", #selector(w.reloadFromDisk(_:))),
            item("Save", #selector(w.saveDocument(_:)), "s"),
            item("Save As...", #selector(w.saveDocumentAs(_:)), "s", [.command, .option]),
            item("Save a Copy As...", #selector(w.saveCopyAs(_:))),
            item("Save All", #selector(w.saveAll(_:)), "s", [.command, .shift]),
            item("Rename...", #selector(w.renameFile(_:))),
            item("Close", #selector(w.closeTab(_:)), "w"),
            item("Close All", #selector(w.closeAll(_:)), "w", [.command, .shift]),
            submenu("Close Multiple Documents", [
                item("Close All BUT This", #selector(w.closeAllButThis(_:))),
                item("Close All to the Left", #selector(w.closeAllLeft(_:))),
                item("Close All to the Right", #selector(w.closeAllRight(_:))),
                item("Close All Unchanged", #selector(w.closeAllUnchanged(_:))),
            ]),
            item("Move to Recycle Bin", #selector(w.moveToTrash(_:))),
            .separator(),
            item("Print...", #selector(w.printDocument(_:)), "p"),
            .separator(),
            recent,
            item("Restore Recent Closed File", #selector(w.restoreClosed(_:)), "t", [.command, .shift]),
            .separator(),
            item("Exit", #selector(NSApplication.terminate(_:))),
        ]))

        main.addItem(submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Delete", #selector(NSText.delete(_:))),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
            item("Begin/End Select", #selector(w.beginEndSelect(_:))),
            item("Begin/End Select in Column Mode", #selector(w.beginEndSelectColumn(_:))),
            .separator(),
            submenu("Insert", [
                item("Date Time (short)", #selector(w.insertDateTime(_:)), tag: 0),
                item("Date Time (long)", #selector(w.insertDateTime(_:)), tag: 1),
                item("Date Time (customized)", #selector(w.insertDateTime(_:)), tag: 2),
            ]),
            submenu("Copy to Clipboard", [
                item("Copy Current Full File Path", #selector(w.copyPathInfo(_:)), tag: 0),
                item("Copy Current Filename", #selector(w.copyPathInfo(_:)), tag: 1),
                item("Copy Current Dir. Path", #selector(w.copyPathInfo(_:)), tag: 2),
                item("Copy All Filenames", #selector(w.copyPathInfo(_:)), tag: 3),
                item("Copy All File Paths", #selector(w.copyPathInfo(_:)), tag: 4),
            ]),
            submenu("Indent", [
                item("Increase Line Indent", #selector(w.changeIndent(_:)), tag: 1),
                item("Decrease Line Indent", #selector(w.changeIndent(_:)), tag: -1),
            ]),
            submenu("Convert Case to", [
                item("UPPERCASE", #selector(w.convertCase(_:)), "u", [.control, .shift], tag: 0),
                item("lowercase", #selector(w.convertCase(_:)), "u", [.control], tag: 1),
                item("Proper Case", #selector(w.convertCase(_:)), "u", [.control, .option], tag: 2),
                item("Proper Case (blend)", #selector(w.convertCase(_:)), tag: 3),
                item("Sentence case", #selector(w.convertCase(_:)), "u", [.control, .option, .shift], tag: 4),
                item("Sentence case (blend)", #selector(w.convertCase(_:)), tag: 5),
                item("iNVERT cASE", #selector(w.convertCase(_:)), tag: 6),
                item("ranDOm CasE", #selector(w.convertCase(_:)), tag: 7),
            ]),
            submenu("Line Operations", [
                item("Duplicate Current Line", #selector(w.lineOperation(_:)), "d", tag: 0),
                item("Remove Duplicate Lines", #selector(w.lineOperation(_:)), tag: 1),
                item("Remove Consecutive Duplicate Lines", #selector(w.lineOperation(_:)), tag: 2),
                item("Split Lines", #selector(w.lineOperation(_:)), "i", [.control], tag: 3),
                item("Join Lines", #selector(w.lineOperation(_:)), "j", [.control], tag: 4),
                item("Move Up Current Line", #selector(w.lineOperation(_:)), up, [.control, .shift], tag: 5),
                item("Move Down Current Line", #selector(w.lineOperation(_:)), down, [.control, .shift], tag: 6),
                item("Delete Current Line", #selector(w.lineOperation(_:)), "l", [.command, .shift], tag: 7),
                item("Remove Empty Lines", #selector(w.lineOperation(_:)), tag: 8),
                item("Remove Empty Lines (Containing Blank characters)", #selector(w.lineOperation(_:)), tag: 9),
                item("Insert Blank Line Above Current", #selector(w.lineOperation(_:)), "\r", [.command, .option], tag: 10),
                item("Insert Blank Line Below Current", #selector(w.lineOperation(_:)), "\r", [.command, .option, .shift], tag: 11),
                .separator(),
                item("Reverse Line Order", #selector(w.lineOperation(_:)), tag: 12),
                item("Sort Lines Lexicographically Ascending", #selector(w.lineOperation(_:)), tag: 13),
                item("Sort Lines Lexicographically Descending", #selector(w.lineOperation(_:)), tag: 14),
                item("Sort Lines Lex. Ascending Ignoring Case", #selector(w.lineOperation(_:)), tag: 15),
                item("Sort Lines Lex. Descending Ignoring Case", #selector(w.lineOperation(_:)), tag: 16),
                item("Sort Lines As Integers Ascending", #selector(w.lineOperation(_:)), tag: 17),
                item("Sort Lines As Integers Descending", #selector(w.lineOperation(_:)), tag: 18),
                item("Randomize Line Order", #selector(w.lineOperation(_:)), tag: 19),
            ]),
            submenu("Comment/Uncomment", [
                item("Toggle Single Line Comment", #selector(w.comment(_:)), "q", [.control], tag: 0),
                item("Single Line Comment", #selector(w.comment(_:)), "k", tag: 1),
                item("Single Line Uncomment", #selector(w.comment(_:)), "k", [.command, .shift], tag: 2),
                item("Block Comment", #selector(w.comment(_:)), "q", [.control, .shift], tag: 3),
                item("Block Uncomment", #selector(w.comment(_:)), tag: 4),
            ]),
            submenu("Auto-Completion", [
                item("Word Completion", #selector(w.wordCompletion(_:)), "\r", [.control]),
            ]),
            submenu("EOL Conversion", EOL.allCases.map { item($0.title, #selector(w.convertEOL(_:)), object: $0.rawValue) }),
            submenu("Blank Operations", [
                item("Trim Trailing Space", #selector(w.blankOperation(_:)), tag: 0),
                item("Trim Leading Space", #selector(w.blankOperation(_:)), tag: 1),
                item("Trim Leading and Trailing Space", #selector(w.blankOperation(_:)), tag: 2),
                item("EOL to Space", #selector(w.blankOperation(_:)), tag: 3),
                item("TAB to Space", #selector(w.blankOperation(_:)), tag: 4),
                item("Space to TAB (All)", #selector(w.blankOperation(_:)), tag: 5),
                item("Space to TAB (Leading)", #selector(w.blankOperation(_:)), tag: 6),
            ]),
            .separator(),
            item("Column Editor...", #selector(w.columnEditor(_:)), "c", [.option]),
            .separator(),
            item("Set Read-Only", #selector(w.toggleReadOnly(_:))),
        ]))

        main.addItem(submenu("Search", [
            item("Find...", #selector(w.showFind(_:)), "f"),
            item("Find in Files...", #selector(w.showFindInFiles(_:)), "f", [.command, .shift]),
            item("Find Next", #selector(w.findNext(_:)), fn(3), []),
            item("Find Previous", #selector(w.findPrevious(_:)), fn(3), [.shift]),
            item("Select and Find Next", #selector(w.selectAndFindNext(_:)), fn(3), [.control]),
            item("Select and Find Previous", #selector(w.selectAndFindPrevious(_:)), fn(3), [.control, .shift]),
            item("Replace...", #selector(w.showReplace(_:)), "h", [.control]),
            .separator(),
            item("Go To...", #selector(w.goToLine(_:)), "g", [.control]),
            item("Go to Matching Brace", #selector(w.goToMatchingBrace(_:)), "b", [.control]),
            item("Select All In-between {} [] or ()", #selector(w.selectBetweenBraces(_:)), "b", [.control, .option]),
            item("Mark...", #selector(w.showMark(_:)), "m", [.control]),
            .separator(),
            submenu("Style All Occurrences of Token", (0..<5).map { item("Using \(["1st", "2nd", "3rd", "4th", "5th"][$0]) Style", #selector(w.styleToken(_:)), tag: $0) }),
            submenu("Clear Style", (0..<5).map { item("Clear \(["1st", "2nd", "3rd", "4th", "5th"][$0]) Style", #selector(w.clearTokenStyle(_:)), tag: $0) }
                    + [item("Clear all Styles", #selector(w.clearTokenStyle(_:)), tag: -1)]),
            .separator(),
            submenu("Bookmark", [
                item("Toggle Bookmark", #selector(w.toggleBookmark(_:)), fn(2), [.control]),
                item("Next Bookmark", #selector(w.nextBookmark(_:)), fn(2), []),
                item("Previous Bookmark", #selector(w.previousBookmark(_:)), fn(2), [.shift]),
                item("Clear All Bookmarks", #selector(w.bookmarkOperation(_:)), tag: 0),
                item("Cut Bookmarked Lines", #selector(w.bookmarkOperation(_:)), tag: 1),
                item("Copy Bookmarked Lines", #selector(w.bookmarkOperation(_:)), tag: 2),
                item("Remove Bookmarked Lines", #selector(w.bookmarkOperation(_:)), tag: 3),
                item("Remove Non-Bookmarked Lines", #selector(w.bookmarkOperation(_:)), tag: 4),
                item("Inverse Bookmark", #selector(w.bookmarkOperation(_:)), tag: 5),
            ]),
        ]))

        main.addItem(submenu("View", [
            item("Always on Top", #selector(w.toggleAlwaysOnTop(_:))),
            item("Toggle Full Screen Mode", #selector(NSWindow.toggleFullScreen(_:)), fn(11), []),
            .separator(),
            submenu("Show Symbol", [
                item("Show Space and Tab", #selector(w.toggleWhitespace(_:))),
                item("Show End of Line", #selector(w.toggleEOL(_:))),
                item("Show All Characters", #selector(w.toggleAllCharacters(_:))),
                .separator(),
                item("Show Indent Guide", #selector(w.toggleIndentGuides(_:))),
                item("Show Wrap Symbol", #selector(w.toggleWrapSymbol(_:))),
            ]),
            submenu("Zoom", [
                item("Zoom In", #selector(w.zoomIn(_:)), "="),
                item("Zoom Out", #selector(w.zoomOut(_:)), "-"),
                item("Restore Default Zoom", #selector(w.zoomReset(_:)), "0"),
            ]),
            .separator(),
            item("Word wrap", #selector(w.toggleWordWrap(_:))),
            .separator(),
            item("Fold All", #selector(w.foldAll(_:)), "0", [.option]),
            item("Unfold All", #selector(w.unfoldAll(_:)), "0", [.option, .shift]),
            item("Collapse Current Level", #selector(w.foldCurrent(_:)), "f", [.control, .option]),
            item("Uncollapse Current Level", #selector(w.unfoldCurrent(_:)), "f", [.control, .option, .shift]),
            submenu("Collapse Level", (1...8).map { item("\($0)", #selector(w.foldLevel(_:)), String($0), [.option], tag: $0) }),
            submenu("Uncollapse Level", (1...8).map { item("\($0)", #selector(w.unfoldLevel(_:)), String($0), [.option, .shift], tag: $0) }),
            .separator(),
            item("Function List", #selector(w.toggleFunctionList(_:))),
            item("Document Map", #selector(w.toggleDocumentMap(_:))),
            item("Search Results", #selector(w.toggleResults(_:))),
            item("Toolbar", #selector(w.toggleToolbar(_:))),
            item("Status Bar", #selector(w.toggleStatusBar(_:))),
            item("Line Numbers", #selector(w.toggleLineNumbers(_:))),
            .separator(),
            item("Summary...", #selector(w.summary(_:))),
        ]))

        main.addItem(NSMenuItem(title: "Encoding", action: nil, keyEquivalent: ""))
        main.items.last?.submenu = encodingMenu()
        main.addItem(NSMenuItem(title: "Language", action: nil, keyEquivalent: ""))
        main.items.last?.submenu = languageMenu()

        main.addItem(submenu("Settings", [
            item("Preferences...", #selector(w.showPreferences(_:))),
            submenu("Style Configurator", [
                item("Follow System", #selector(w.setTheme(_:)), object: "system"),
                item("Default (light)", #selector(w.setTheme(_:)), object: "light"),
                item("Dark", #selector(w.setTheme(_:)), object: "dark"),
                .separator(),
                item("Font...", #selector(w.chooseFont(_:))),
            ]),
        ]))

        let macroMenu = submenu("Macro", [])
        macroMenu.submenu?.delegate = MacroMenu.shared
        main.addItem(macroMenu)

        let runMenu = submenu("Run", [])
        runMenu.submenu?.delegate = RunMenu.shared
        main.addItem(runMenu)

        let windowMenu = submenu("Window", [])
        windowMenu.submenu?.delegate = WindowMenu.shared
        main.addItem(windowMenu)
        NSApp.windowsMenu = nil

        main.addItem(submenu("?", [
            item("About Notepad++", #selector(AppDelegate.about(_:)), fn(1), []),
            item("Notepad++ for Mac on GitHub", #selector(AppDelegate.openHomepage(_:))),
        ]))
        return main
    }

    static func encodingMenu() -> NSMenu {
        let menu = NSMenu(title: "Encoding")
        for encoding in TextEncoding.allCases {
            menu.addItem(item(encoding.title, #selector(EditorWindow.encodeIn(_:)), object: encoding.rawValue))
        }
        menu.addItem(.separator())
        for encoding in TextEncoding.allCases {
            menu.addItem(item("Convert to \(encoding.title)", #selector(EditorWindow.convertTo(_:)), object: encoding.rawValue))
        }
        return menu
    }

    /// Languages grouped by first letter, like Notepad++.
    static func languageMenu() -> NSMenu {
        let menu = NSMenu(title: "Language")
        menu.addItem(item("Normal Text", #selector(EditorWindow.setLanguage(_:)), object: Language.normal.name))
        menu.addItem(.separator())
        let groups = Dictionary(grouping: Language.all.dropFirst()) { String($0.name.uppercased().first!) }
        for letter in groups.keys.sorted() {
            let languages = groups[letter]!.sorted { $0.name < $1.name }
            menu.addItem(submenu(letter, languages.map { item($0.name, #selector(EditorWindow.setLanguage(_:)), object: $0.name) }))
        }
        return menu
    }

    static func tabMenu() -> NSMenu {
        let w = EditorWindow.self
        let menu = NSMenu()
        [item("Close", #selector(w.closeTab(_:))), item("Close All BUT This", #selector(w.closeAllButThis(_:))),
         item("Close All to the Left", #selector(w.closeAllLeft(_:))), item("Close All to the Right", #selector(w.closeAllRight(_:))),
         item("Close All Unchanged", #selector(w.closeAllUnchanged(_:))), .separator(),
         item("Save", #selector(w.saveDocument(_:))), item("Save As...", #selector(w.saveDocumentAs(_:))),
         item("Rename...", #selector(w.renameFile(_:))), item("Move to Recycle Bin", #selector(w.moveToTrash(_:))),
         item("Reload from Disk", #selector(w.reloadFromDisk(_:))), item("Print...", #selector(w.printDocument(_:))), .separator(),
         item("Open Containing Folder in Finder", #selector(w.revealInFinder(_:))), item("Open Containing Folder in Terminal", #selector(w.openInTerminal(_:))),
         .separator(), item("Read-Only", #selector(w.toggleReadOnly(_:))), .separator(),
         item("Copy Full File Path", #selector(w.copyPathInfo(_:)), tag: 0), item("Copy Filename", #selector(w.copyPathInfo(_:)), tag: 1),
         item("Copy Current Dir. Path", #selector(w.copyPathInfo(_:)), tag: 2),
        ].forEach(menu.addItem)
        return menu
    }
}

/// File > Recent Files, rebuilt each time it opens.
@MainActor
final class RecentMenu: NSObject, NSMenuDelegate {
    static let shared = RecentMenu()

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for (i, path) in Preferences.recentFiles.enumerated() {
            let item = NSMenuItem(title: "\(i + 1): \(path)", action: #selector(EditorWindow.openRecent(_:)), keyEquivalent: "")
            item.representedObject = path
            menu.addItem(item)
        }
        if menu.items.isEmpty { menu.addItem(NSMenuItem(title: "No recent files", action: nil, keyEquivalent: "")) }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Open All Recent Files", action: #selector(EditorWindow.openAllRecent(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Empty Recent Files List", action: #selector(EditorWindow.clearRecent(_:)), keyEquivalent: ""))
    }
}

/// Macro menu with the saved macros.
@MainActor
final class MacroMenu: NSObject, NSMenuDelegate {
    static let shared = MacroMenu()

    func menuNeedsUpdate(_ menu: NSMenu) {
        let w = EditorWindow.self
        menu.removeAllItems()
        let items: [(String, Selector, String, NSEvent.ModifierFlags)] = [
            ("Start Recording", #selector(w.startRecording(_:)), "r", [.command, .shift]),
            ("Stop Recording", #selector(w.stopRecording(_:)), "r", [.command, .shift, .option]),
            ("Playback", #selector(w.playMacro(_:)), "p", [.command, .shift]),
            ("Save Current Recorded Macro...", #selector(w.saveMacro(_:)), "", []),
            ("Run a Macro Multiple Times...", #selector(w.runMacroMultiple(_:)), "", []),
        ]
        for (title, action, key, mods) in items {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Trim Trailing Space and Save", action: #selector(w.trimAndSave(_:)), keyEquivalent: ""))
        let saved = Preferences.savedMacros.keys.sorted()
        if !saved.isEmpty {
            menu.addItem(.separator())
            for name in saved {
                let item = NSMenuItem(title: name, action: #selector(w.playSavedMacro(_:)), keyEquivalent: "")
                item.representedObject = name
                menu.addItem(item)
            }
            menu.addItem(.separator())
            let delete = NSMenuItem(title: "Delete Saved Macro", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for name in saved {
                let item = NSMenuItem(title: name, action: #selector(w.deleteMacro(_:)), keyEquivalent: "")
                item.representedObject = name
                sub.addItem(item)
            }
            delete.submenu = sub
            menu.addItem(delete)
        }
    }
}

/// Run menu: Run... (F5), recent commands, and launching the file in a browser or Terminal.
@MainActor
final class RunMenu: NSObject, NSMenuDelegate {
    static let shared = RunMenu()

    func menuNeedsUpdate(_ menu: NSMenu) {
        let w = EditorWindow.self
        menu.removeAllItems()
        let run = NSMenuItem(title: "Run...", action: #selector(w.runCommand(_:)), keyEquivalent: String(UnicodeScalar(NSF5FunctionKey)!))
        run.keyEquivalentModifierMask = []
        menu.addItem(run)
        for command in Preferences.runCommands {
            let item = NSMenuItem(title: command, action: #selector(w.runSavedCommand(_:)), keyEquivalent: "")
            item.representedObject = command
            menu.addItem(item)
        }
        menu.addItem(.separator())
        for (title, bundle) in [("Launch in Safari", "com.apple.Safari"), ("Launch in Chrome", "com.google.Chrome"),
                                ("Launch in Firefox", "org.mozilla.firefox"), ("Launch in Edge", "com.microsoft.edgemac")]
            where NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) != nil {
            let item = NSMenuItem(title: title, action: #selector(w.launchInBrowser(_:)), keyEquivalent: "")
            item.representedObject = bundle
            menu.addItem(item)
        }
        menu.addItem(NSMenuItem(title: "Open Containing Folder in Terminal", action: #selector(w.openInTerminal(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Search on Internet", action: #selector(w.searchOnInternet(_:)), keyEquivalent: ""))
    }
}

/// Window menu: the open documents, sorting, and next/previous tab.
@MainActor
final class WindowMenu: NSObject, NSMenuDelegate {
    static let shared = WindowMenu()

    func menuNeedsUpdate(_ menu: NSMenu) {
        let w = EditorWindow.self
        menu.removeAllItems()
        let next = NSMenuItem(title: "Next Tab", action: #selector(w.nextTab(_:)), keyEquivalent: "\t")
        next.keyEquivalentModifierMask = [.control]
        let previous = NSMenuItem(title: "Previous Tab", action: #selector(w.previousTab(_:)), keyEquivalent: "\t")
        previous.keyEquivalentModifierMask = [.control, .shift]
        menu.addItem(next)
        menu.addItem(previous)
        let sort = NSMenuItem(title: "Sort By", action: nil, keyEquivalent: "")
        let sortMenu = NSMenu()
        for (i, title) in ["Name A to Z", "Name Z to A", "Path A to Z", "Path Z to A", "Type A to Z", "Type Z to A"].enumerated() {
            let item = NSMenuItem(title: title, action: #selector(w.sortTabs(_:)), keyEquivalent: "")
            item.tag = i
            sortMenu.addItem(item)
        }
        sort.submenu = sortMenu
        menu.addItem(sort)
        menu.addItem(.separator())
        guard let window = (NSApp.delegate as? AppDelegate)?.window else { return }
        for (i, doc) in window.documents.enumerated() {
            let item = NSMenuItem(title: "\(doc.isModified ? "*" : "")\(doc.name)", action: #selector(w.selectTabFromMenu(_:)),
                                  keyEquivalent: i < 9 ? String(i + 1) : "")
            item.keyEquivalentModifierMask = [.command]
            item.tag = i
            item.state = i == window.currentIndex ? .on : .off
            item.toolTip = doc.url?.path
            menu.addItem(item)
        }
    }
}
