import AppKit
import Scintilla

/// Typed access to Scintilla's message API. Positions are byte offsets into the UTF-8 text.
extension ScintillaView {
    @discardableResult
    func send(_ msg: Int32, _ w: Int = 0, _ l: Int = 0) -> Int {
        message(UInt32(msg), wParam: UInt(bitPattern: w), lParam: l)
    }

    @discardableResult
    func send(_ msg: Int32, _ w: Int = 0, text: String) -> Int {
        text.withCString { send(msg, w, Int(bitPattern: $0)) }
    }

    @discardableResult
    func send(_ msg: Int32, _ w: Int = 0, bytes: Data) -> Int {
        var data = bytes
        data.append(0)
        return data.withUnsafeBytes { send(msg, w, Int(bitPattern: $0.baseAddress)) }
    }

    /// Calls a message that copies a NUL-terminated string into lParam and returns its length when lParam is 0.
    func string(_ msg: Int32, _ w: Int = 0) -> String {
        let length = send(msg, w, 0)
        guard length > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: length + 1)
        buffer.withUnsafeMutableBufferPointer { _ = send(msg, w, Int(bitPattern: $0.baseAddress)) }
        return String(cString: buffer)
    }

    var length: Int { send(SCI_GETLENGTH) }

    /// The whole document as UTF-8.
    var data: Data {
        let length = self.length
        var buffer = Data(count: length + 1)
        buffer.withUnsafeMutableBytes { _ = send(SCI_GETTEXT, length + 1, Int(bitPattern: $0.baseAddress)) }
        return buffer.prefix(length)
    }

    var text: String {
        get { String(decoding: data, as: UTF8.self) }
        set { send(SCI_SETTEXT, 0, text: newValue) }
    }

    func text(from start: Int, to end: Int) -> String {
        guard end > start else { return "" }
        var buffer = [CChar](repeating: 0, count: end - start + 1)
        buffer.withUnsafeMutableBufferPointer { pointer in
            var range = Sci_TextRangeFull(chrg: Sci_CharacterRangeFull(cpMin: start, cpMax: end), lpstrText: pointer.baseAddress)
            _ = withUnsafeMutablePointer(to: &range) { send(SCI_GETTEXTRANGEFULL, 0, Int(bitPattern: $0)) }
        }
        return String(cString: buffer)
    }

    var selectedText: String { text(from: selectionStart, to: selectionEnd) }
    var currentPos: Int { send(SCI_GETCURRENTPOS) }
    var selectionStart: Int { send(SCI_GETSELECTIONSTART) }
    var selectionEnd: Int { send(SCI_GETSELECTIONEND) }
    var lineCount: Int { send(SCI_GETLINECOUNT) }
    var currentLine: Int { line(of: currentPos) }
    func line(of position: Int) -> Int { send(SCI_LINEFROMPOSITION, position) }
    func lineStart(_ line: Int) -> Int { send(SCI_POSITIONFROMLINE, line) }
    func lineEnd(_ line: Int) -> Int { send(SCI_GETLINEENDPOSITION, line) }
    func lineText(_ line: Int) -> String { text(from: lineStart(line), to: lineEnd(line)) }

    /// Replaces start..<end and returns the length of the new text in bytes.
    @discardableResult
    func replace(from start: Int, to end: Int, with text: String) -> Int {
        send(SCI_SETTARGETRANGE, start, end)
        return send(SCI_REPLACETARGET, text.utf8.count, text: text)
    }

    func select(_ start: Int, _ end: Int) {
        send(SCI_SETSEL, start, end)
        send(SCI_SCROLLCARET)
    }

    func goTo(line: Int) {
        send(SCI_ENSUREVISIBLEENFORCEPOLICY, line)
        send(SCI_GOTOLINE, line)
        send(SCI_VERTICALCENTRECARET)
    }

    /// Wraps several edits into one undo step.
    func undoGroup(_ body: () -> Void) {
        send(SCI_BEGINUNDOACTION)
        body()
        send(SCI_ENDUNDOACTION)
    }

    func setProperty(_ key: String, _ value: String) {
        key.withCString { k in value.withCString { v in _ = send(SCI_SETPROPERTY, Int(bitPattern: k), Int(bitPattern: v)) } }
    }

    /// Scintilla colours are 0x00BBGGRR; with alpha 0xAABBGGRR.
    static func color(_ rgb: UInt32, alpha: UInt32? = nil) -> Int {
        let bgr = (rgb & 0xFF) << 16 | (rgb & 0xFF00) | (rgb >> 16 & 0xFF)
        return Int(bgr | (alpha ?? 0) << 24)
    }
}
