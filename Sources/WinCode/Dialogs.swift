import AppKit
import Scintilla

/// Edit > Column Editor (Alt+C): insert text, or a number sequence, on every line from the caret down
/// (or on each line of a column selection).
@MainActor
enum ColumnEditor {
    static func run(_ e: ScintillaView, in window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = "Column / Multi-Selection Editor"
        let textMode = NSButton(radioButtonWithTitle: "Text to Insert", target: nil, action: nil)
        let numberMode = NSButton(radioButtonWithTitle: "Number to Insert", target: nil, action: nil)
        textMode.state = .on
        let pair = RadioPair(textMode, numberMode)
        let text = NSTextField(string: "")
        let initial = NSTextField(string: "1")
        let increase = NSTextField(string: "1")
        let repeatCount = NSTextField(string: "1")
        let leading = NSPopUpButton()
        leading.addItems(withTitles: ["None", "Zeros", "Spaces"])
        let format = NSPopUpButton()
        format.addItems(withTitles: ["Dec", "Hex", "Oct", "Bin"])
        for field in [text, initial, increase, repeatCount] { field.widthAnchor.constraint(equalToConstant: 160).isActive = true }
        let grid = NSGridView(views: [
            [textMode, NSGridCell.emptyContentView],
            [NSTextField(labelWithString: ""), text],
            [numberMode, NSGridCell.emptyContentView],
            [NSTextField(labelWithString: "Initial number :"), initial],
            [NSTextField(labelWithString: "Increase by :"), increase],
            [NSTextField(labelWithString: "Repeat :"), repeatCount],
            [NSTextField(labelWithString: "Leading :"), leading],
            [NSTextField(labelWithString: "Format :"), format],
        ])
        grid.rowSpacing = 6
        grid.frame = NSRect(x: 0, y: 0, width: 300, height: 240)
        alert.accessoryView = grid
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = text
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        _ = pair

        // Where to insert: each selection of a column selection, else the caret column on every line below.
        var positions: [Int] = []
        let selections = e.send(SCI_GETSELECTIONS)
        if selections > 1 || e.send(SCI_GETSELECTIONMODE) == Int(SC_SEL_RECTANGLE) {
            for i in 0..<selections { positions.append(e.send(SCI_GETSELECTIONNSTART, i)) }
        } else {
            let column = e.send(SCI_GETCOLUMN, e.currentPos)
            for line in e.currentLine..<e.lineCount {
                let pos = e.send(SCI_FINDCOLUMN, line, column)
                positions.append(e.send(SCI_GETCOLUMN, pos) == column ? pos : -line - 1)
            }
        }
        let radix = [10, 16, 8, 2][format.indexOfSelectedItem]
        let start = initial.integerValue, step = increase.integerValue, repeats = max(1, repeatCount.integerValue)
        let count = positions.count
        let lastValue = start + step * ((count - 1) / repeats)
        let width = String(max(abs(start), abs(lastValue)), radix: radix).count
        func number(_ index: Int) -> String {
            let value = start + step * (index / repeats)
            var s = String(value, radix: radix).uppercased()
            switch leading.indexOfSelectedItem {
            case 1: s = String(repeating: "0", count: max(0, width - s.count)) + s
            case 2: s = String(repeating: " ", count: max(0, width - s.count)) + s
            default: break
            }
            return s
        }
        let column = e.send(SCI_GETCOLUMN, e.currentPos)
        e.undoGroup {
            for (index, pos) in positions.enumerated().reversed() {
                let insert = numberMode.state == .on ? number(index) : text.stringValue
                if pos >= 0 {
                    e.send(SCI_INSERTTEXT, pos, text: insert)
                } else {
                    // A line shorter than the column: pad it with spaces first.
                    let line = -pos - 1
                    let end = e.lineEnd(line)
                    let padding = max(0, column - e.send(SCI_GETCOLUMN, end))
                    e.send(SCI_INSERTTEXT, end, text: String(repeating: " ", count: padding) + insert)
                }
            }
        }
    }
}

/// Settings > Preferences.
@MainActor
final class PreferencesWindow: NSWindowController {
    static let shared = PreferencesWindow()
    private weak var editorWindow: EditorWindow?

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 460), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Preferences"
        super.init(window: window)
        build()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(owner: EditorWindow) {
        self.editorWindow = owner
        build()
        showWindow(nil)
    }

    private func check(_ title: String, _ value: Bool, _ apply: @escaping (Bool) -> Void) -> NSButton {
        let button = ClosureButton(checkboxWithTitle: title, target: nil, action: nil)
        button.state = value ? .on : .off
        button.onClick = { [weak self] b in
            apply(b.state == .on)
            self?.editorWindow?.applyPreferencesToAll()
        }
        return button
    }

    private func build() {
        guard let content = window?.contentView else { return }
        content.subviews.forEach { $0.removeFromSuperview() }

        let tabWidth = NSStepper()
        tabWidth.minValue = 1
        tabWidth.maxValue = 16
        tabWidth.integerValue = Preferences.tabWidth
        let tabLabel = NSTextField(labelWithString: "\(Preferences.tabWidth)")
        let tabTarget = StepperTarget { value in
            Preferences.tabWidth = value
            tabLabel.stringValue = "\(value)"
        } onApply: { [weak self] in self?.editorWindow?.applyPreferencesToAll() }
        tabWidth.target = tabTarget
        tabWidth.action = #selector(StepperTarget.changed(_:))
        objc_setAssociatedObject(tabWidth, "target", tabTarget, .OBJC_ASSOCIATION_RETAIN)

        let eol = NSPopUpButton()
        eol.addItems(withTitles: EOL.allCases.map(\.title))
        eol.selectItem(at: EOL.allCases.firstIndex(of: Preferences.newEOL) ?? 0)
        let eolTarget = PopupTarget { Preferences.newEOL = EOL.allCases[$0] }
        eol.target = eolTarget
        eol.action = #selector(PopupTarget.changed(_:))
        objc_setAssociatedObject(eol, "target", eolTarget, .OBJC_ASSOCIATION_RETAIN)

        let encoding = NSPopUpButton()
        encoding.addItems(withTitles: TextEncoding.allCases.map(\.title))
        encoding.selectItem(at: TextEncoding.allCases.firstIndex(of: Preferences.newEncoding) ?? 1)
        let encodingTarget = PopupTarget { Preferences.newEncoding = TextEncoding.allCases[$0] }
        encoding.target = encodingTarget
        encoding.action = #selector(PopupTarget.changed(_:))
        objc_setAssociatedObject(encoding, "target", encodingTarget, .OBJC_ASSOCIATION_RETAIN)

        let completionChars = NSPopUpButton()
        completionChars.addItems(withTitles: (1...9).map { "From \($0)th character" })
        completionChars.itemArray.enumerated().forEach { $0.element.title = "From \($0.offset + 1) character\($0.offset == 0 ? "" : "s")" }
        completionChars.selectItem(at: Preferences.autoCompletionChars - 1)
        let completionTarget = PopupTarget { Preferences.autoCompletionChars = $0 + 1 }
        completionChars.target = completionTarget
        completionChars.action = #selector(PopupTarget.changed(_:))
        objc_setAssociatedObject(completionChars, "target", completionTarget, .OBJC_ASSOCIATION_RETAIN)

        let font = NSButton(title: "\(Preferences.fontName) \(Preferences.fontSize)pt...", target: editorWindow, action: #selector(EditorWindow.chooseFont(_:)))

        let rows: [[NSView]] = [
            [NSTextField(labelWithString: "Font:"), font],
            [NSTextField(labelWithString: "Tab size:"), NSStackView(views: [tabLabel, tabWidth])],
            [NSTextField(labelWithString: ""), check("Replace tabs by spaces", Preferences.useSpaces) { Preferences.useSpaces = $0 }],
            [NSTextField(labelWithString: "New document:"), NSStackView(views: [eol, encoding])],
            [NSTextField(labelWithString: "Editing:"), check("Highlight current line", Preferences.highlightCurrentLine) { Preferences.highlightCurrentLine = $0 }],
            [NSTextField(labelWithString: ""), check("Smart highlighting (other occurrences of the selected word)", Preferences.smartHighlight) { Preferences.smartHighlight = $0 }],
            [NSTextField(labelWithString: ""), check("Auto-indent", Preferences.autoIndent) { Preferences.autoIndent = $0 }],
            [NSTextField(labelWithString: ""), check("Auto-close ( [ { \" '", Preferences.autoClose) { Preferences.autoClose = $0 }],
            [NSTextField(labelWithString: "Margins:"), check("Display line numbers", Preferences.showLineNumbers) { Preferences.showLineNumbers = $0 }],
            [NSTextField(labelWithString: ""), check("Display bookmark margin", Preferences.showBookmarkMargin) { Preferences.showBookmarkMargin = $0 }],
            [NSTextField(labelWithString: "Auto-Completion:"), check("Enable auto-completion on each input", Preferences.autoCompletion) { Preferences.autoCompletion = $0 }],
            [NSTextField(labelWithString: ""), completionChars],
            [NSTextField(labelWithString: "Backup:"), check("Remember current session (and unsaved changes) for next launch", Preferences.restoreSession) { Preferences.restoreSession = $0 }],
        ]
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
        ])
    }
}

final class ClosureButton: NSButton {
    var onClick: ((NSButton) -> Void)? {
        didSet {
            target = self
            action = #selector(clicked)
        }
    }
    @objc private func clicked() { onClick?(self) }
}

final class StepperTarget: NSObject {
    private let change: (Int) -> Void
    private let apply: () -> Void
    init(_ change: @escaping (Int) -> Void, onApply: @escaping () -> Void) {
        self.change = change
        self.apply = onApply
    }
    @objc func changed(_ sender: NSStepper) {
        change(sender.integerValue)
        apply()
    }
}

final class PopupTarget: NSObject {
    private let change: (Int) -> Void
    init(_ change: @escaping (Int) -> Void) { self.change = change }
    @objc func changed(_ sender: NSPopUpButton) { change(sender.indexOfSelectedItem) }
}
