import AppKit

/// Settings > Preferences, stored in UserDefaults.
enum Preferences {
    private static let defaults = UserDefaults.standard

    private static func bool(_ key: String, _ fallback: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
    }

    private static func int(_ key: String, _ fallback: Int) -> Int {
        defaults.object(forKey: key) == nil ? fallback : defaults.integer(forKey: key)
    }

    /// "system", "light" or "dark".
    static var theme: String {
        get { defaults.string(forKey: "theme") ?? "system" }
        set { defaults.set(newValue, forKey: "theme") }
    }
    static var fontName: String {
        get { defaults.string(forKey: "fontName") ?? defaultFont }
        set { defaults.set(newValue, forKey: "fontName") }
    }
    static var fontSize: Int {
        get { int("fontSize", 12) }
        set { defaults.set(newValue, forKey: "fontSize") }
    }
    static var tabWidth: Int {
        get { int("tabWidth", 4) }
        set { defaults.set(newValue, forKey: "tabWidth") }
    }
    static var useSpaces: Bool {
        get { bool("useSpaces", false) }
        set { defaults.set(newValue, forKey: "useSpaces") }
    }
    static var wordWrap: Bool {
        get { bool("wordWrap", false) }
        set { defaults.set(newValue, forKey: "wordWrap") }
    }
    static var showWhitespace: Bool {
        get { bool("showWhitespace", false) }
        set { defaults.set(newValue, forKey: "showWhitespace") }
    }
    static var showEOL: Bool {
        get { bool("showEOL", false) }
        set { defaults.set(newValue, forKey: "showEOL") }
    }
    static var showIndentGuides: Bool {
        get { bool("showIndentGuides", true) }
        set { defaults.set(newValue, forKey: "showIndentGuides") }
    }
    static var showWrapSymbol: Bool {
        get { bool("showWrapSymbol", false) }
        set { defaults.set(newValue, forKey: "showWrapSymbol") }
    }
    static var showLineNumbers: Bool {
        get { bool("showLineNumbers", true) }
        set { defaults.set(newValue, forKey: "showLineNumbers") }
    }
    static var showBookmarkMargin: Bool {
        get { bool("showBookmarkMargin", true) }
        set { defaults.set(newValue, forKey: "showBookmarkMargin") }
    }
    static var highlightCurrentLine: Bool {
        get { bool("highlightCurrentLine", true) }
        set { defaults.set(newValue, forKey: "highlightCurrentLine") }
    }
    static var smartHighlight: Bool {
        get { bool("smartHighlight", true) }
        set { defaults.set(newValue, forKey: "smartHighlight") }
    }
    static var autoCompletion: Bool {
        get { bool("autoCompletion", true) }
        set { defaults.set(newValue, forKey: "autoCompletion") }
    }
    static var autoCompletionChars: Int {
        get { int("autoCompletionChars", 3) }
        set { defaults.set(newValue, forKey: "autoCompletionChars") }
    }
    static var autoClose: Bool {
        get { bool("autoClose", false) }
        set { defaults.set(newValue, forKey: "autoClose") }
    }
    static var autoIndent: Bool {
        get { bool("autoIndent", true) }
        set { defaults.set(newValue, forKey: "autoIndent") }
    }
    static var restoreSession: Bool {
        get { bool("restoreSession", true) }
        set { defaults.set(newValue, forKey: "restoreSession") }
    }
    static var showToolbar: Bool {
        get { bool("showToolbar", true) }
        set { defaults.set(newValue, forKey: "showToolbar") }
    }
    static var showStatusBar: Bool {
        get { bool("showStatusBar", true) }
        set { defaults.set(newValue, forKey: "showStatusBar") }
    }
    static var showDocumentMap: Bool {
        get { bool("showDocumentMap", false) }
        set { defaults.set(newValue, forKey: "showDocumentMap") }
    }
    static var showFunctionList: Bool {
        get { bool("showFunctionList", false) }
        set { defaults.set(newValue, forKey: "showFunctionList") }
    }
    static var alwaysOnTop: Bool {
        get { bool("alwaysOnTop", false) }
        set { defaults.set(newValue, forKey: "alwaysOnTop") }
    }
    /// New documents: "crlf" (Windows, the Notepad++ default), "lf" or "cr".
    static var newEOL: EOL {
        get { EOL(rawValue: defaults.string(forKey: "newEOL") ?? "") ?? .crlf }
        set { defaults.set(newValue.rawValue, forKey: "newEOL") }
    }
    static var newEncoding: TextEncoding {
        get { TextEncoding(rawValue: defaults.string(forKey: "newEncoding") ?? "") ?? .utf8 }
        set { defaults.set(newValue.rawValue, forKey: "newEncoding") }
    }
    static var recentFiles: [String] {
        get { defaults.stringArray(forKey: "recentFiles") ?? [] }
        set { defaults.set(Array(newValue.prefix(15)), forKey: "recentFiles") }
    }
    static var savedMacros: [String: [[String: Any]]] {
        get { defaults.dictionary(forKey: "macros") as? [String: [[String: Any]]] ?? [:] }
        set { defaults.set(newValue, forKey: "macros") }
    }
    static var runCommands: [String] {
        get { defaults.stringArray(forKey: "runCommands") ?? [] }
        set { defaults.set(Array(newValue.prefix(10)), forKey: "runCommands") }
    }

    static func addRecent(_ path: String) {
        recentFiles = [path] + recentFiles.filter { $0 != path }
    }

    /// Consolas if it is installed (Notepad++'s font on Windows), else the Mac's monospaced font.
    static let defaultFont: String = {
        let installed = NSFontManager.shared.availableFontFamilies
        return ["Consolas", "SF Mono", "Menlo"].first(where: installed.contains) ?? "Menlo"
    }()
}
