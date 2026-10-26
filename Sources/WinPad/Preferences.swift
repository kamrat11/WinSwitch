import AppKit

/// WinPad settings, stored in UserDefaults (domain com.kamrat.WinPad). Changes post `Preferences.changed`.
@MainActor
enum Preferences {
    static let changed = Notification.Name("WinPadPreferencesChanged")
    private static let defaults = UserDefaults.standard

    enum Theme: String, CaseIterable {
        case system, light, dark

        var title: String {
            switch self {
            case .system: return "Use system setting"
            case .light: return "Light"
            case .dark: return "Dark"
            }
        }
    }

    static var theme: Theme {
        get { Theme(rawValue: defaults.string(forKey: "theme") ?? "") ?? .system }
        set { defaults.set(newValue.rawValue, forKey: "theme"); applyTheme(); notify() }
    }

    static func applyTheme() {
        switch theme {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    /// Consolas when installed (it comes with Microsoft Office), else Menlo.
    static var defaultFont: NSFont {
        NSFont(name: "Consolas", size: 14) ?? NSFont(name: "Menlo", size: 13)
            ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
    }

    static var font: NSFont {
        get {
            if let name = defaults.string(forKey: "fontName"), let font = NSFont(name: name, size: CGFloat(defaults.double(forKey: "fontSize"))) {
                return font
            }
            return defaultFont
        }
        set {
            defaults.set(newValue.fontName, forKey: "fontName")
            defaults.set(Double(newValue.pointSize), forKey: "fontSize")
            notify()
        }
    }

    static var wordWrap: Bool {
        get { defaults.bool(forKey: "wordWrap") }
        set { defaults.set(newValue, forKey: "wordWrap"); notify() }
    }

    static var statusBar: Bool {
        get { defaults.object(forKey: "statusBar") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "statusBar"); notify() }
    }

    /// "Opening Notepad": true opens the content from the previous session, false starts a new session.
    static var restoreSession: Bool {
        get { defaults.object(forKey: "restoreSession") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "restoreSession"); notify() }
    }

    static var recentFiles: [URL] {
        get { (defaults.stringArray(forKey: "recentFiles") ?? []).map { URL(fileURLWithPath: $0) } }
        set { defaults.set(newValue.prefix(10).map(\.path), forKey: "recentFiles") }
    }

    static func noteRecent(_ url: URL) {
        recentFiles = [url] + recentFiles.filter { $0.path != url.path }
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    private static func notify() { NotificationCenter.default.post(name: changed, object: nil) }
}
