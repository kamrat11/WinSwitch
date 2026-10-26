import AppKit

/// Remembers the open windows and tabs, including unsaved text, so the next launch continues where this one
/// stopped (Windows 11 Notepad's "Open content from a previous session").
@MainActor
enum Session {
    struct Tab: Codable {
        var path: String?
        var text: String?          // only for unsaved changes and Untitled tabs
        var encoding: TextEncoding
        var lineEnding: LineEnding
        var modified: Bool
        var selection: Int
        var zoom: Int
    }

    struct Window: Codable {
        var frame: String
        var tabs: [Tab]
        var selected: Int
    }

    private static var file: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WinPad", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("session.json")
    }

    /// Tab groups front to back.
    private static func groups() -> [[Editor]] {
        var seen = Set<ObjectIdentifier>()
        var result: [[Editor]] = []
        let windows = NSApp.orderedWindows.filter { $0.windowController is Editor }
            + Editor.all.compactMap(\.window)
        for window in windows where !seen.contains(ObjectIdentifier(window)) {
            let group = window.tabbedWindows ?? [window]
            group.forEach { seen.insert(ObjectIdentifier($0)) }
            let editors = group.compactMap { $0.windowController as? Editor }
            if !editors.isEmpty { result.append(editors) }
        }
        return result
    }

    static func save() {
        let windows = groups().map { editors -> Window in
            let tabs = editors.map { e in
                Tab(path: e.url?.path, text: e.isModified || e.url == nil ? e.text : nil,
                    encoding: e.encoding, lineEnding: e.lineEnding, modified: e.isModified,
                    selection: e.textView.selectedRange().location, zoom: e.zoom)
            }
            let first = editors[0].window!
            let selected = editors.firstIndex { $0.window === first.tabGroup?.selectedWindow } ?? 0
            return Window(frame: NSStringFromRect(first.frame), tabs: tabs, selected: selected)
        }
        if let data = try? JSONEncoder().encode(windows) { try? data.write(to: file, options: .atomic) }
    }

    static func clear() { try? FileManager.default.removeItem(at: file) }

    /// Reopens the saved windows. Returns false when there was nothing to restore.
    @discardableResult
    static func restore() -> Bool {
        guard let data = try? Data(contentsOf: file),
              let windows = try? JSONDecoder().decode([Window].self, from: data) else { return false }
        var restored = false
        for saved in windows.reversed() {
            var first: Editor?
            var previous: Editor?
            var selected: Editor?
            for (i, tab) in saved.tabs.enumerated() {
                let url = tab.path.map { URL(fileURLWithPath: $0) }
                var contents = TextFile.Contents(text: tab.text ?? "", encoding: tab.encoding, lineEnding: tab.lineEnding)
                if !tab.modified, let url {
                    guard let disk = try? TextFile.read(url) else { continue }
                    contents = disk
                }
                let editor = Editor.open(contents, url: url, modified: tab.modified, asTabOf: previous?.window,
                                         frame: first == nil ? NSRectFromString(saved.frame) : nil)
                editor.setZoom(tab.zoom)
                editor.restoreSelection(tab.selection)
                if first == nil { first = editor }
                previous = editor
                if i == saved.selected { selected = editor }
                restored = true
            }
            (selected ?? first)?.window?.makeKeyAndOrderFront(nil)
        }
        return restored
    }
}
