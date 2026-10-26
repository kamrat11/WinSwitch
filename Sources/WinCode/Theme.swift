import AppKit
import Scintilla

/// Colours for the editor, like Notepad++'s Style Configurator themes.
struct Theme {
    struct Style {
        var fg: UInt32
        var bg: UInt32? = nil
        var bold = false
        var italic = false
    }

    let name: String
    let fg: UInt32
    let bg: UInt32
    let caretLine: UInt32
    let selection: UInt32
    let margin: UInt32
    let marginText: UInt32
    let fold: UInt32
    let caret: UInt32
    let whitespace: UInt32
    let smartHighlight: UInt32
    let findMark: UInt32
    let braceMatch: Style
    let braceBad: Style
    let tokens: [TokenKind: Style]

    /// Notepad++'s default ("Default" in the Style Configurator).
    static let light = Theme(
        name: "Default", fg: 0x000000, bg: 0xFFFFFF, caretLine: 0xE8E8FF, selection: 0xC0C0C0, margin: 0xE4E4E4, marginText: 0x808080,
        fold: 0xF3F3F3, caret: 0x8000FF, whitespace: 0xFFB56A, smartHighlight: 0x00FF00, findMark: 0xFF0000,
        braceMatch: Style(fg: 0xFF0000, bg: 0xFFFFFF, bold: true), braceBad: Style(fg: 0x800000, bg: 0xFFFFFF, bold: true),
        tokens: [
            .comment: Style(fg: 0x008000), .commentDoc: Style(fg: 0x008080),
            .number: Style(fg: 0xFF8000), .keyword: Style(fg: 0x0000FF, bold: true), .type: Style(fg: 0x8000FF),
            .function: Style(fg: 0x8A0000, bold: true), .string: Style(fg: 0x808080), .regex: Style(fg: 0x8000FF),
            .preprocessor: Style(fg: 0x804000), .operator: Style(fg: 0x000080, bold: true),
            .tag: Style(fg: 0x0000FF), .attribute: Style(fg: 0xFF0000), .entity: Style(fg: 0x8000FF),
            .variable: Style(fg: 0x000080), .label: Style(fg: 0x804000, bold: true), .heading: Style(fg: 0x0000FF, bold: true),
            .emphasis: Style(fg: 0x8000FF, italic: true), .link: Style(fg: 0x0000FF), .error: Style(fg: 0xFF0000, bg: 0xFFFF80),
            .added: Style(fg: 0x008000, bg: 0xE0FFE0), .deleted: Style(fg: 0x800000, bg: 0xFFE0E0), .changed: Style(fg: 0x000080),
        ])

    /// A dark theme in the style of Notepad++'s "Obsidian".
    static let dark = Theme(
        name: "Dark", fg: 0xE0E2E4, bg: 0x22282A, caretLine: 0x2F393C, selection: 0x404E51, margin: 0x2B3134, marginText: 0x81969A,
        fold: 0x22282A, caret: 0xFFFFFF, whitespace: 0x546A71, smartHighlight: 0x7CB342, findMark: 0xFF6060,
        braceMatch: Style(fg: 0xFFFFFF, bg: 0x4F6C77, bold: true), braceBad: Style(fg: 0xFF6060, bold: true),
        tokens: [
            .comment: Style(fg: 0x7D8C93), .commentDoc: Style(fg: 0x8BA7A7),
            .number: Style(fg: 0xFFCD22), .keyword: Style(fg: 0x93C763, bold: true), .type: Style(fg: 0x678CB1),
            .function: Style(fg: 0xD39745), .string: Style(fg: 0xEC7600), .regex: Style(fg: 0xD39745),
            .preprocessor: Style(fg: 0xA082BD), .operator: Style(fg: 0xE8E2B7),
            .tag: Style(fg: 0x8CBBAD), .attribute: Style(fg: 0xE0A8F0), .entity: Style(fg: 0xA082BD),
            .variable: Style(fg: 0xB3B689), .label: Style(fg: 0xD39745, bold: true), .heading: Style(fg: 0x93C763, bold: true),
            .emphasis: Style(fg: 0xE0A8F0, italic: true), .link: Style(fg: 0x6FA8DC), .error: Style(fg: 0xFF6060),
            .added: Style(fg: 0x93C763, bg: 0x22382A), .deleted: Style(fg: 0xFF8080, bg: 0x3A2426), .changed: Style(fg: 0x678CB1),
        ])

    static var current: Theme {
        switch Preferences.theme {
        case "light": return .light
        case "dark": return .dark
        default:
            let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return dark ? .dark : .light
        }
    }
}

/// Indicator numbers (Notepad++ uses the same idea: smart highlight, find marks and the five "Style token" colours).
enum Indicator {
    static let smartHighlight: Int32 = 29
    static let findMark: Int32 = 28
    static let tokenStyles: [Int32] = [21, 22, 23, 24, 25]
    static let tokenColors: [UInt32] = [0x00FFFF, 0xFF8000, 0xFFFF00, 0x8080FF, 0x008000]
}

/// Marker numbers.
enum Marker {
    static let bookmark: Int32 = 24
}
