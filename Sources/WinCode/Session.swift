import AppKit
import Scintilla

/// Notepad++'s session snapshot: the open tabs, unsaved changes included, come back on the next launch.
/// Unsaved text is kept in ~/Library/Application Support/WinCode/backup.
@MainActor
enum Session {
    private static let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("WinCode", isDirectory: true)
    private static var file: URL { folder.appendingPathComponent("session.plist") }
    private static var backups: URL { folder.appendingPathComponent("backup", isDirectory: true) }

    static func save(_ window: EditorWindow) {
        try? FileManager.default.removeItem(at: backups)
        try? FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        var tabs: [[String: Any]] = []
        for (index, doc) in window.documents.enumerated() {
            let e = doc.editor
            var tab: [String: Any] = [
                "language": doc.language.name, "encoding": doc.encoding.rawValue, "eol": doc.eol.rawValue,
                "caret": e.currentPos, "anchor": e.send(SCI_GETANCHOR), "firstLine": e.send(SCI_GETFIRSTVISIBLELINE),
                "zoom": e.send(SCI_GETZOOM), "untitled": doc.untitledNumber, "readOnly": doc.readOnly,
                "bookmarks": Editing.bookmarkedLines(e),
            ]
            if let url = doc.url { tab["path"] = url.path }
            if doc.isModified || doc.url == nil {
                guard doc.isModified || e.length > 0 else { continue } // an empty "new 1"
                let backup = backups.appendingPathComponent("\(index).txt")
                try? e.data.write(to: backup)
                tab["backup"] = backup.path
                if let date = doc.fileDate { tab["fileDate"] = date }
            }
            tabs.append(tab)
        }
        let session: [String: Any] = ["tabs": tabs, "selected": window.currentIndex]
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        (session as NSDictionary).write(to: file, atomically: true)
    }

    /// Restores the last session; returns false when there was none.
    @discardableResult
    static func restore(_ window: EditorWindow) -> Bool {
        guard Preferences.restoreSession, let session = NSDictionary(contentsOf: file) as? [String: Any],
              let tabs = session["tabs"] as? [[String: Any]], !tabs.isEmpty else { return false }
        for tab in tabs {
            let path = tab["path"] as? String
            let backup = tab["backup"] as? String
            let doc: Document
            if let backup, let data = FileManager.default.contents(atPath: backup) {
                // Backups exist only for unsaved text, so the tab comes back modified.
                doc = window.addDocument(select: false)
                doc.editor.text = String(decoding: data, as: UTF8.self)
                doc.editor.send(SCI_EMPTYUNDOBUFFER)
                if let path {
                    doc.url = URL(fileURLWithPath: path)
                    doc.fileDate = tab["fileDate"] as? Date ?? Document.modificationDate(URL(fileURLWithPath: path))
                }
                markModified(doc)
            } else if let path, FileManager.default.fileExists(atPath: path) {
                guard let opened = window.open([URL(fileURLWithPath: path)]) else { continue }
                doc = opened
            } else {
                continue
            }
            if let untitled = tab["untitled"] as? Int, doc.url == nil { doc.untitledNumber = untitled }
            if let raw = tab["encoding"] as? String, let encoding = TextEncoding(rawValue: raw) { doc.encoding = encoding }
            if let raw = tab["eol"] as? String, let eol = EOL(rawValue: raw) {
                doc.eol = eol
                doc.editor.send(SCI_SETEOLMODE, eol.mode)
            }
            if let name = tab["language"] as? String, let language = Language.named(name), language != doc.language { doc.setLanguage(language) }
            let e = doc.editor
            let length = e.length
            e.send(SCI_SETSEL, min(tab["anchor"] as? Int ?? 0, length), min(tab["caret"] as? Int ?? 0, length))
            e.send(SCI_SETFIRSTVISIBLELINE, tab["firstLine"] as? Int ?? 0)
            e.send(SCI_SETZOOM, tab["zoom"] as? Int ?? 0)
            for line in tab["bookmarks"] as? [Int] ?? [] { e.send(SCI_MARKERADD, line, Int(Marker.bookmark)) }
            if tab["readOnly"] as? Bool == true { doc.readOnly = true }
        }
        window.renumberUntitled()
        window.refreshTabs()
        let selected = session["selected"] as? Int ?? 0
        window.select(min(selected, window.documents.count - 1))
        return !window.documents.isEmpty
    }

    /// Scintilla has no "set modified": make an edit and take it back after the save point.
    private static func markModified(_ doc: Document) {
        let e = doc.editor
        e.send(SCI_SETSAVEPOINT)
        e.undoGroup {
            e.send(SCI_INSERTTEXT, 0, text: " ")
            e.send(SCI_DELETERANGE, 0, 1)
        }
    }
}
