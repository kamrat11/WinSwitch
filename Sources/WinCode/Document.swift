import AppKit
import Scintilla

enum EOL: String, CaseIterable {
    case crlf, lf, cr

    var title: String {
        switch self {
        case .crlf: return "Windows (CR LF)"
        case .lf: return "Unix (LF)"
        case .cr: return "Macintosh (CR)"
        }
    }
    var mode: Int {
        switch self {
        case .crlf: return Int(SC_EOL_CRLF)
        case .lf: return Int(SC_EOL_LF)
        case .cr: return Int(SC_EOL_CR)
        }
    }

    /// The most common line ending in the text (Windows when there are none).
    static func detect(_ data: Data) -> EOL {
        var crlf = 0, lf = 0, cr = 0
        var previous: UInt8 = 0
        for byte in data.prefix(1 << 20) {
            if byte == 10 { if previous == 13 { crlf += 1; cr -= 1 } else { lf += 1 } }
            if byte == 13 { cr += 1 }
            previous = byte
        }
        if crlf == 0 && lf == 0 && cr == 0 { return Preferences.newEOL }
        if lf > crlf && lf >= cr { return .lf }
        if cr > crlf && cr > lf { return .cr }
        return .crlf
    }
}

/// The Encoding menu's choices.
enum TextEncoding: String, CaseIterable {
    case ansi, utf8, utf8BOM, utf16BE, utf16LE

    var title: String {
        switch self {
        case .ansi: return "ANSI"
        case .utf8: return "UTF-8"
        case .utf8BOM: return "UTF-8-BOM"
        case .utf16BE: return "UTF-16 BE BOM"
        case .utf16LE: return "UTF-16 LE BOM"
        }
    }

    var bom: [UInt8] {
        switch self {
        case .utf8BOM: return [0xEF, 0xBB, 0xBF]
        case .utf16BE: return [0xFE, 0xFF]
        case .utf16LE: return [0xFF, 0xFE]
        default: return []
        }
    }

    var foundation: String.Encoding {
        switch self {
        case .ansi: return .windowsCP1252
        case .utf8, .utf8BOM: return .utf8
        case .utf16BE: return .utf16BigEndian
        case .utf16LE: return .utf16LittleEndian
        }
    }

    /// BOM first, then valid UTF-8, else ANSI (Windows-1252), like Notepad++.
    static func detect(_ data: Data) -> TextEncoding {
        let bytes = [UInt8](data.prefix(3))
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { return .utf8BOM }
        if bytes.starts(with: [0xFF, 0xFE]) { return .utf16LE }
        if bytes.starts(with: [0xFE, 0xFF]) { return .utf16BE }
        return String(data: data, encoding: .utf8) != nil ? .utf8 : .ansi
    }

    func decode(_ data: Data) -> String? {
        String(data: data.dropFirst(data.starts(with: bom) ? bom.count : 0), encoding: foundation)
    }

    func encode(_ text: String) -> Data? {
        guard let body = text.data(using: foundation, allowLossyConversion: false) else { return nil }
        return Data(bom) + body
    }
}

/// One open tab: a Scintilla view with its file, encoding, line ending and language.
@MainActor
final class Document: NSObject, ScintillaNotificationProtocol {
    let editor: ScintillaView
    var url: URL? { didSet { owner?.documentChanged(self) } }
    var untitledNumber = 0
    var encoding = Preferences.newEncoding
    var eol = Preferences.newEOL
    var language = Language.normal
    var readOnly = false { didSet { editor.send(SCI_SETREADONLY, readOnly ? 1 : 0); owner?.documentChanged(self) } }
    /// Modification date of the file when it was last loaded or saved, to notice changes by other programs.
    var fileDate: Date?
    weak var owner: EditorWindow?

    var isModified: Bool { editor.send(SCI_GETMODIFY) != 0 }
    var name: String { url?.lastPathComponent ?? "new \(untitledNumber)" }

    init(owner: EditorWindow) {
        self.owner = owner
        editor = ScintillaView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        super.init()
        editor.delegate = self
        configureEditor()
    }

    // MARK: Loading and saving

    func load(_ url: URL, encoding forced: TextEncoding? = nil) throws {
        let data = try Data(contentsOf: url)
        let encoding = forced ?? TextEncoding.detect(data)
        let text = encoding.decode(data) ?? String(decoding: data, as: UTF8.self)
        self.url = url
        self.encoding = encoding
        eol = EOL.detect(data)
        editor.send(SCI_SETREADONLY, 0)
        editor.send(SCI_SETEOLMODE, eol.mode)
        editor.send(SCI_CLEARALL)
        editor.text = text
        editor.send(SCI_EMPTYUNDOBUFFER)
        editor.send(SCI_SETSAVEPOINT)
        editor.send(SCI_GOTOPOS, 0)
        fileDate = Self.modificationDate(url)
        readOnly = !FileManager.default.isWritableFile(atPath: url.path)
        let firstLine = String(text.prefix(200).split(separator: "\n", maxSplits: 1).first ?? "")
        setLanguage(Language.detect(url: url, firstLine: firstLine))
    }

    func save(to url: URL) throws {
        guard let data = encoding.encode(editor.text) else {
            throw NSError(domain: "WinCode", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "The text contains characters that \(encoding.title) can't store. Choose Encoding > Convert to UTF-8 and save again."])
        }
        try data.write(to: url, options: .atomic)
        let wasUntitled = self.url == nil
        self.url = url
        fileDate = Self.modificationDate(url)
        editor.send(SCI_SETSAVEPOINT)
        if wasUntitled || language == .normal {
            setLanguage(Language.detect(url: url, firstLine: editor.lineText(0)))
        }
    }

    static func modificationDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    // MARK: Editor setup

    func configureEditor() {
        let e = editor
        e.send(SCI_SETCODEPAGE, Int(SC_CP_UTF8))
        e.send(SCI_SETTECHNOLOGY, Int(SC_TECHNOLOGY_DEFAULT))
        e.send(SCI_SETEOLMODE, eol.mode)
        e.send(SCI_SETMULTIPLESELECTION, 1)
        e.send(SCI_SETADDITIONALSELECTIONTYPING, 1)
        e.send(SCI_SETMULTIPASTE, Int(SC_MULTIPASTE_EACH))
        e.send(SCI_SETVIRTUALSPACEOPTIONS, Int(SCVS_RECTANGULARSELECTION))
        e.send(SCI_SETMOUSESELECTIONRECTANGULARSWITCH, 1)
        e.send(SCI_SETSCROLLWIDTHTRACKING, 1)
        e.send(SCI_SETSCROLLWIDTH, 1)
        e.send(SCI_SETENDATLASTLINE, 1)
        e.send(SCI_SETCARETWIDTH, 2)
        e.send(SCI_SETMOUSEDWELLTIME, 500)
        e.send(SCI_AUTOCSETIGNORECASE, 1)
        e.send(SCI_AUTOCSETCASEINSENSITIVEBEHAVIOUR, Int(SC_CASEINSENSITIVEBEHAVIOUR_IGNORECASE))
        e.send(SCI_AUTOCSETMAXHEIGHT, 10)
        e.send(SCI_AUTOCSETORDER, Int(SC_ORDER_PERFORMSORT))
        e.send(SCI_SETAUTOMATICFOLD, Int(SC_AUTOMATICFOLD_SHOW | SC_AUTOMATICFOLD_CLICK | SC_AUTOMATICFOLD_CHANGE))
        e.send(SCI_SETFOLDFLAGS, Int(SC_FOLDFLAG_LINEAFTER_CONTRACTED))
        e.send(SCI_SETMODEVENTMASK, Int(SC_MOD_INSERTTEXT | SC_MOD_DELETETEXT))

        // Margins: 0 line numbers, 1 bookmarks, 2 folding.
        e.send(SCI_SETMARGINTYPEN, 0, Int(SC_MARGIN_NUMBER))
        e.send(SCI_SETMARGINTYPEN, 1, Int(SC_MARGIN_SYMBOL))
        e.send(SCI_SETMARGINMASKN, 1, 1 << Int(Marker.bookmark))
        e.send(SCI_SETMARGINSENSITIVEN, 1, 1)
        e.send(SCI_SETMARGINTYPEN, 2, Int(SC_MARGIN_SYMBOL))
        e.send(SCI_SETMARGINMASKN, 2, Int(SC_MASK_FOLDERS))
        e.send(SCI_SETMARGINSENSITIVEN, 2, 1)
        e.send(SCI_MARKERDEFINE, Int(Marker.bookmark), Int(SC_MARK_BOOKMARK))
        let folds: [(Int32, Int32)] = [
            (SC_MARKNUM_FOLDEROPEN, SC_MARK_BOXMINUS), (SC_MARKNUM_FOLDER, SC_MARK_BOXPLUS),
            (SC_MARKNUM_FOLDERSUB, SC_MARK_VLINE), (SC_MARKNUM_FOLDERTAIL, SC_MARK_LCORNER),
            (SC_MARKNUM_FOLDEREND, SC_MARK_BOXPLUSCONNECTED), (SC_MARKNUM_FOLDEROPENMID, SC_MARK_BOXMINUSCONNECTED),
            (SC_MARKNUM_FOLDERMIDTAIL, SC_MARK_TCORNER),
        ]
        for (number, symbol) in folds { e.send(SCI_MARKERDEFINE, Int(number), Int(symbol)) }
        e.send(SCI_MARKERENABLEHIGHLIGHT, 1)

        // Indicators.
        e.send(SCI_INDICSETSTYLE, Int(Indicator.smartHighlight), Int(INDIC_ROUNDBOX))
        e.send(SCI_INDICSETALPHA, Int(Indicator.smartHighlight), 100)
        e.send(SCI_INDICSETOUTLINEALPHA, Int(Indicator.smartHighlight), 160)
        e.send(SCI_INDICSETUNDER, Int(Indicator.smartHighlight), 1)
        e.send(SCI_INDICSETSTYLE, Int(Indicator.findMark), Int(INDIC_ROUNDBOX))
        e.send(SCI_INDICSETALPHA, Int(Indicator.findMark), 100)
        e.send(SCI_INDICSETUNDER, Int(Indicator.findMark), 1)
        for (indicator, color) in zip(Indicator.tokenStyles, Indicator.tokenColors) {
            e.send(SCI_INDICSETSTYLE, Int(indicator), Int(INDIC_FULLBOX))
            e.send(SCI_INDICSETFORE, Int(indicator), ScintillaView.color(color))
            e.send(SCI_INDICSETALPHA, Int(indicator), 110)
            e.send(SCI_INDICSETUNDER, Int(indicator), 1)
        }
        applyPreferences()
    }

    /// Applies the View and Settings options and the theme; called again when they change.
    func applyPreferences() {
        let e = editor
        let tab = Preferences.tabWidth
        e.send(SCI_SETTABWIDTH, tab)
        e.send(SCI_SETINDENT, tab)
        e.send(SCI_SETUSETABS, Preferences.useSpaces ? 0 : 1)
        e.send(SCI_SETTABINDENTS, 1)
        e.send(SCI_SETBACKSPACEUNINDENTS, 1)
        e.send(SCI_SETWRAPMODE, Int(Preferences.wordWrap ? SC_WRAP_WORD : SC_WRAP_NONE))
        e.send(SCI_SETWRAPVISUALFLAGS, Int(Preferences.showWrapSymbol ? SC_WRAPVISUALFLAG_END : SC_WRAPVISUALFLAG_NONE))
        e.send(SCI_SETVIEWWS, Int(Preferences.showWhitespace ? SCWS_VISIBLEALWAYS : SCWS_INVISIBLE))
        e.send(SCI_SETVIEWEOL, Preferences.showEOL ? 1 : 0)
        e.send(SCI_SETINDENTATIONGUIDES, Int(Preferences.showIndentGuides ? SC_IV_LOOKBOTH : SC_IV_NONE))
        e.send(SCI_SETCARETLINEVISIBLE, Preferences.highlightCurrentLine ? 1 : 0)
        e.send(SCI_SETCARETLINEVISIBLEALWAYS, 1)
        applyTheme()
        updateMargins()
    }

    func applyTheme() {
        let e = editor, t = Theme.current
        let c = ScintillaView.color
        // Scrollers and the corner match the editor, not the system appearance.
        e.appearance = NSAppearance(named: t.name == Theme.dark.name ? .darkAqua : .aqua)
        e.send(SCI_STYLESETFONT, Int(STYLE_DEFAULT), text: Preferences.fontName)
        e.send(SCI_STYLESETSIZE, Int(STYLE_DEFAULT), Preferences.fontSize)
        e.send(SCI_STYLESETFORE, Int(STYLE_DEFAULT), c(t.fg, nil))
        e.send(SCI_STYLESETBACK, Int(STYLE_DEFAULT), c(t.bg, nil))
        e.send(SCI_STYLECLEARALL)
        e.send(SCI_STYLESETFORE, Int(STYLE_LINENUMBER), c(t.marginText, nil))
        e.send(SCI_STYLESETBACK, Int(STYLE_LINENUMBER), c(t.margin, nil))
        e.send(SCI_STYLESETFORE, Int(STYLE_BRACELIGHT), c(t.braceMatch.fg, nil))
        e.send(SCI_STYLESETBACK, Int(STYLE_BRACELIGHT), c(t.braceMatch.bg ?? t.bg, nil))
        e.send(SCI_STYLESETBOLD, Int(STYLE_BRACELIGHT), 1)
        e.send(SCI_STYLESETFORE, Int(STYLE_BRACEBAD), c(t.braceBad.fg, nil))
        e.send(SCI_STYLESETBOLD, Int(STYLE_BRACEBAD), 1)
        e.send(SCI_STYLESETFORE, Int(STYLE_INDENTGUIDE), c(t.whitespace, nil))
        e.send(SCI_STYLESETFORE, Int(STYLE_CONTROLCHAR), c(t.fg, nil))
        e.send(SCI_SETCARETFORE, c(t.caret, nil))
        e.send(SCI_SETCARETLINEBACK, c(t.caretLine, nil))
        e.send(SCI_SETSELBACK, 1, c(t.selection, nil))
        e.send(SCI_SETELEMENTCOLOUR, Int(SC_ELEMENT_SELECTION_INACTIVE_BACK), c(t.selection, 0xA0))
        e.send(SCI_SETWHITESPACEFORE, 1, c(t.whitespace, nil))
        e.send(SCI_SETFOLDMARGINCOLOUR, 1, c(t.fold, nil))
        e.send(SCI_SETFOLDMARGINHICOLOUR, 1, c(t.fold, nil))
        e.send(SCI_SETMARGINBACKN, 1, c(t.margin, nil))
        let foldFore = t.bg, foldBack = t.marginText
        for number in [SC_MARKNUM_FOLDEROPEN, SC_MARKNUM_FOLDER, SC_MARKNUM_FOLDERSUB, SC_MARKNUM_FOLDERTAIL,
                       SC_MARKNUM_FOLDEREND, SC_MARKNUM_FOLDEROPENMID, SC_MARKNUM_FOLDERMIDTAIL] {
            e.send(SCI_MARKERSETFORE, Int(number), c(foldFore, nil))
            e.send(SCI_MARKERSETBACK, Int(number), c(foldBack, nil))
            e.send(SCI_MARKERSETBACKSELECTED, Int(number), c(0xFF0000, nil))
        }
        e.send(SCI_MARKERSETFORE, Int(Marker.bookmark), c(0x2060D0, nil))
        e.send(SCI_MARKERSETBACK, Int(Marker.bookmark), c(0x4A90E2, nil))
        e.send(SCI_INDICSETFORE, Int(Indicator.smartHighlight), c(t.smartHighlight, nil))
        e.send(SCI_INDICSETFORE, Int(Indicator.findMark), c(t.findMark, nil))
        e.send(SCI_SETELEMENTCOLOUR, Int(SC_ELEMENT_LIST_BACK), c(t.bg, 0xFF))
        e.send(SCI_SETELEMENTCOLOUR, Int(SC_ELEMENT_LIST), c(t.fg, 0xFF))

        // Token colours from the lexer's style table.
        for (style, kind) in LexerStyles.table[language.lexer] ?? [:] {
            guard let s = t.tokens[kind] else { continue }
            e.send(SCI_STYLESETFORE, style, c(s.fg, nil))
            if let bg = s.bg { e.send(SCI_STYLESETBACK, style, c(bg, nil)) }
            e.send(SCI_STYLESETBOLD, style, s.bold ? 1 : 0)
            e.send(SCI_STYLESETITALIC, style, s.italic ? 1 : 0)
            if kind == .error || kind == .added || kind == .deleted { e.send(SCI_STYLESETEOLFILLED, style, 1) }
        }
        e.send(SCI_COLOURISE, 0, -1)
    }

    func updateMargins() {
        let e = editor
        let digits = max(3, String(e.lineCount).count)
        let width = Preferences.showLineNumbers ? e.send(SCI_TEXTWIDTH, Int(STYLE_LINENUMBER), text: "_" + String(repeating: "9", count: digits)) + 6 : 0
        if e.send(SCI_GETMARGINWIDTHN, 0) != width { e.send(SCI_SETMARGINWIDTHN, 0, width) }
        e.send(SCI_SETMARGINWIDTHN, 1, Preferences.showBookmarkMargin ? 16 : 0)
        e.send(SCI_SETMARGINWIDTHN, 2, language.lexer == "null" ? 0 : 14)
    }

    func setLanguage(_ language: Language) {
        self.language = language
        let e = editor
        e.send(SCI_SETILEXER, 0, Int(bitPattern: ScintillaCreateLexer(language.lexer)))
        for (index, words) in language.keywords.enumerated() where !words.isEmpty {
            e.send(SCI_SETKEYWORDS, index, text: words)
        }
        for (key, value) in ["fold": "1", "fold.compact": "0", "fold.comment": "1", "fold.preprocessor": "1"] {
            e.setProperty(key, value)
        }
        for (key, value) in language.properties { e.setProperty(key, value) }
        applyTheme()
        updateMargins()
        owner?.documentChanged(self)
    }

    // MARK: Notifications

    nonisolated func notification(_ notification: UnsafeMutablePointer<SCNotification>!) {
        let scn = notification.pointee
        MainActor.assumeIsolated { owner?.editorNotification(self, scn) }
    }
}
