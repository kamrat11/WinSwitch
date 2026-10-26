import AppKit

/// Hidden launch switches that put the window in a given state, for screenshots in automated checks:
/// --debug-tab N, --debug-find TEXT (Find All in all documents), --debug-dialog find|replace|files|mark|preferences|saveas.
@MainActor
enum DebugLaunch {
    private static let args = CommandLine.arguments

    private static func value(_ flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// The values of the switches, so they aren't opened as files.
    static var values: Set<String> {
        Set(["--debug-tab", "--debug-find", "--debug-dialog"].compactMap(value))
    }

    static func run(_ window: EditorWindow) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if let tab = value("--debug-tab").flatMap(Int.init) { window.select(tab) }
            if let text = value("--debug-find") {
                var o = SearchOptions()
                o.text = text
                Search.options = o
                window.results.add(search: o, documents: window.documents)
                if let e = window.editor { Search.findNext(e, o) }
            }
            switch value("--debug-dialog") {
            case "find": window.showFind(nil)
            case "replace": window.showReplace(nil)
            case "files": window.showFindInFiles(nil)
            case "mark": window.showMark(nil)
            case "preferences": window.showPreferences(nil)
            case "saveas": window.saveDocumentAs(nil)
            default: break
            }
        }
    }
}
