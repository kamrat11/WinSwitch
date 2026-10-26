import AppKit
import Scintilla

/// Editor behaviour and the Edit menu's text operations.
@MainActor
enum Editing {
    // MARK: As you type

    static func matchBraces(_ e: ScintillaView) {
        let braces = Set("()[]{}<>".utf8)
        var pos = e.currentPos
        var ch = UInt8(truncatingIfNeeded: e.send(SCI_GETCHARAT, pos))
        if !braces.contains(ch) || ch == UInt8(ascii: "<") || ch == UInt8(ascii: ">"), pos > 0 {
            let before = UInt8(truncatingIfNeeded: e.send(SCI_GETCHARAT, pos - 1))
            if braces.contains(before) { pos -= 1; ch = before }
        }
        guard braces.contains(ch) else {
            e.send(SCI_BRACEHIGHLIGHT, -1, -1)
            e.send(SCI_SETHIGHLIGHTGUIDE, 0)
            return
        }
        let match = e.send(SCI_BRACEMATCH, pos, 0)
        if match < 0 {
            e.send(SCI_BRACEBADLIGHT, pos)
        } else {
            e.send(SCI_BRACEHIGHLIGHT, pos, match)
            e.send(SCI_SETHIGHLIGHTGUIDE, e.send(SCI_GETCOLUMN, min(pos, match)))
        }
    }

    /// Highlights every other occurrence of the selected word, like Notepad++'s smart highlighting.
    static func smartHighlight(_ e: ScintillaView) {
        let length = e.length
        e.send(SCI_SETINDICATORCURRENT, Int(Indicator.smartHighlight))
        e.send(SCI_INDICATORCLEARRANGE, 0, length)
        guard Preferences.smartHighlight, e.send(SCI_GETSELECTIONS) == 1 else { return }
        let start = e.selectionStart, end = e.selectionEnd
        guard end > start, end - start < 200, e.line(of: start) == e.line(of: end) else { return }
        // Only whole words, so selecting part of a word doesn't light up the document.
        guard e.send(SCI_WORDSTARTPOSITION, start, 1) == start, e.send(SCI_WORDENDPOSITION, start, 1) == end else { return }
        let word = e.selectedText
        guard !word.isEmpty, word.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return }
        // Limit the work to the visible lines plus a margin on large files.
        let first = e.send(SCI_GETFIRSTVISIBLELINE)
        let docFirst = e.send(SCI_DOCLINEFROMVISIBLE, first)
        let visible = e.send(SCI_LINESONSCREEN)
        let range = length > 2_000_000
            ? (e.lineStart(max(0, docFirst - 50)), e.lineEnd(min(e.lineCount - 1, docFirst + visible + 50)))
            : (0, length)
        e.send(SCI_SETSEARCHFLAGS, Int(SCFIND_MATCHCASE | SCFIND_WHOLEWORD))
        var from = range.0
        while from < range.1 {
            e.send(SCI_SETTARGETRANGE, from, range.1)
            let found = e.send(SCI_SEARCHINTARGET, word.utf8.count, text: word)
            guard found >= 0 else { break }
            let foundEnd = e.send(SCI_GETTARGETEND)
            if found != start { e.send(SCI_INDICATORFILLRANGE, found, foundEnd - found) }
            from = max(foundEnd, found + 1)
        }
    }

    static func charAdded(_ doc: Document, _ ch: Int) {
        let e = doc.editor
        if ch == 10 || (ch == 13 && doc.eol == .cr) {
            guard Preferences.autoIndent else { return }
            let line = e.currentLine
            guard line > 0 else { return }
            let indent = e.send(SCI_GETLINEINDENTATION, line - 1)
            var extra = 0
            let previous = e.lineText(line - 1).trimmingCharacters(in: .whitespaces)
            if previous.hasSuffix("{") || previous.hasSuffix("[") || previous.hasSuffix("(")
                || (doc.language.name == "Python" && previous.hasSuffix(":")) {
                extra = Preferences.tabWidth
            }
            e.send(SCI_SETLINEINDENTATION, line, indent + extra)
            e.send(SCI_GOTOPOS, e.send(SCI_GETLINEINDENTPOSITION, line))
            return
        }
        if ch == Int(UInt8(ascii: "}")) && Preferences.autoIndent {
            // Outdent a lone closing brace to the line that opened the block.
            let line = e.currentLine
            if e.lineText(line).trimmingCharacters(in: .whitespaces) == "}" {
                let match = e.send(SCI_BRACEMATCH, e.currentPos - 1, 0)
                if match >= 0 {
                    e.send(SCI_SETLINEINDENTATION, line, e.send(SCI_GETLINEINDENTATION, e.line(of: match)))
                    e.send(SCI_GOTOPOS, e.lineEnd(line))
                }
            }
        }
        if Preferences.autoClose, let close = ["(": ")", "[": "]", "{": "}", "\"": "\"", "'": "'"][String(UnicodeScalar(UInt8(clamping: ch)))] {
            let next = UInt8(truncatingIfNeeded: e.send(SCI_GETCHARAT, e.currentPos))
            if next == 0 || next == 10 || next == 13 || next == 32 || next == 9 || ")]}".utf8.contains(next) {
                e.send(SCI_INSERTTEXT, e.currentPos, text: close)
            }
        }
        if Preferences.autoCompletion, let scalar = UnicodeScalar(ch), CharacterSet.alphanumerics.contains(scalar) || ch == 95 {
            showCompletion(doc, minimum: Preferences.autoCompletionChars)
        }
    }

    /// Word and keyword completion (Ctrl+Enter, or as you type after a few letters).
    static func showCompletion(_ doc: Document, minimum: Int) {
        let e = doc.editor
        let pos = e.currentPos
        let start = e.send(SCI_WORDSTARTPOSITION, pos, 1)
        let typed = pos - start
        guard typed >= minimum else { return }
        let prefix = e.text(from: start, to: pos).lowercased()
        var words = Set<String>()
        for list in doc.language.keywords {
            for word in list.split(separator: " ") where word.lowercased().hasPrefix(prefix) { words.insert(String(word)) }
        }
        let text = e.length < 4_000_000 ? e.text : e.text(from: max(0, pos - 500_000), to: min(e.length, pos + 500_000))
        var current = ""
        for char in text {
            if char.isLetter || char.isNumber || char == "_" {
                current.append(char)
            } else {
                if current.count > typed, current.lowercased().hasPrefix(prefix) { words.insert(current) }
                current = ""
            }
            if words.count > 500 { break }
        }
        if current.count > typed, current.lowercased().hasPrefix(prefix) { words.insert(current) }
        words.remove(e.text(from: start, to: e.send(SCI_WORDENDPOSITION, pos, 1)))
        guard !words.isEmpty else { return }
        e.send(SCI_AUTOCSETSEPARATOR, 10)
        e.send(SCI_AUTOCSHOW, typed, text: words.sorted { $0.lowercased() < $1.lowercased() }.joined(separator: "\n"))
    }

    // MARK: Bookmarks

    static func toggleBookmark(_ e: ScintillaView, line: Int) {
        if e.send(SCI_MARKERGET, line) & (1 << Int(Marker.bookmark)) != 0 {
            e.send(SCI_MARKERDELETE, line, Int(Marker.bookmark))
        } else {
            e.send(SCI_MARKERADD, line, Int(Marker.bookmark))
        }
    }

    static func nextBookmark(_ e: ScintillaView, forward: Bool) {
        let mask = 1 << Int(Marker.bookmark)
        let line = e.currentLine
        var found = forward ? e.send(SCI_MARKERNEXT, line + 1, mask) : e.send(SCI_MARKERPREVIOUS, line - 1, mask)
        if found < 0 { found = forward ? e.send(SCI_MARKERNEXT, 0, mask) : e.send(SCI_MARKERPREVIOUS, e.lineCount, mask) }
        if found >= 0 { e.goTo(line: found) }
    }

    static func bookmarkedLines(_ e: ScintillaView) -> [Int] {
        let mask = 1 << Int(Marker.bookmark)
        var lines: [Int] = []
        var line = e.send(SCI_MARKERNEXT, 0, mask)
        while line >= 0 {
            lines.append(line)
            line = e.send(SCI_MARKERNEXT, line + 1, mask)
        }
        return lines
    }

    // MARK: Line operations

    /// The lines touched by the selection (the whole document when nothing is selected and `wholeDocument`).
    static func selectedLines(_ e: ScintillaView, wholeDocument: Bool = true) -> ClosedRange<Int> {
        let start = e.selectionStart, end = e.selectionEnd
        if start == end && wholeDocument { return 0...max(0, e.lineCount - 1) }
        var last = e.line(of: end)
        if last > e.line(of: start) && e.lineStart(last) == end { last -= 1 }
        return e.line(of: start)...last
    }

    /// Replaces the given lines with `transform`'s result as one undo step.
    static func transformLines(_ e: ScintillaView, wholeDocument: Bool = true, _ transform: ([String]) -> [String]) {
        let range = selectedLines(e, wholeDocument: wholeDocument)
        let start = e.lineStart(range.lowerBound), end = e.lineEnd(range.upperBound)
        let lines = range.map { e.lineText($0) }
        let newText = transform(lines).joined(separator: eolString(e))
        e.undoGroup { e.replace(from: start, to: end, with: newText) }
        e.select(start, start + newText.utf8.count)
    }

    static func eolString(_ e: ScintillaView) -> String {
        switch Int32(e.send(SCI_GETEOLMODE)) {
        case SC_EOL_CRLF: return "\r\n"
        case SC_EOL_CR: return "\r"
        default: return "\n"
        }
    }

    static func sortLines(_ e: ScintillaView, descending: Bool, numeric: Bool = false, caseInsensitive: Bool = false) {
        transformLines(e) { lines in
            let sorted = lines.sorted { a, b in
                if numeric {
                    let x = Double(a.trimmingCharacters(in: .whitespaces).prefix { "0123456789.-+".contains($0) }) ?? 0
                    let y = Double(b.trimmingCharacters(in: .whitespaces).prefix { "0123456789.-+".contains($0) }) ?? 0
                    return x < y
                }
                return caseInsensitive ? a.localizedCaseInsensitiveCompare(b) == .orderedAscending : a < b
            }
            return descending ? sorted.reversed() : sorted
        }
    }

    static func removeDuplicateLines(_ e: ScintillaView, consecutiveOnly: Bool) {
        transformLines(e) { lines in
            var seen = Set<String>()
            var result: [String] = []
            for line in lines {
                if consecutiveOnly { if result.last != line { result.append(line) } }
                else if seen.insert(line).inserted { result.append(line) }
            }
            return result
        }
    }

    static func removeEmptyLines(_ e: ScintillaView, blankToo: Bool) {
        transformLines(e) { lines in
            lines.filter { blankToo ? !$0.trimmingCharacters(in: .whitespaces).isEmpty : !$0.isEmpty }
        }
    }

    static func trim(_ e: ScintillaView, leading: Bool, trailing: Bool) {
        transformLines(e) { lines in
            lines.map { line in
                var s = Substring(line)
                if leading { s = s.drop { $0 == " " || $0 == "\t" } }
                if trailing { while let last = s.last, last == " " || last == "\t" { s = s.dropLast() } }
                return String(s)
            }
        }
    }

    static func tabsToSpaces(_ e: ScintillaView, leadingOnly: Bool = false) {
        let width = Preferences.tabWidth
        transformLines(e) { lines in
            lines.map { line in
                var out = ""
                var column = 0
                var leading = true
                for ch in line {
                    if ch == "\t" && (!leadingOnly || leading) {
                        let n = width - column % width
                        out += String(repeating: " ", count: n)
                        column += n
                    } else {
                        if ch != " " && ch != "\t" { leading = false }
                        out.append(ch)
                        column += 1
                    }
                }
                return out
            }
        }
    }

    static func spacesToTabs(_ e: ScintillaView, leadingOnly: Bool) {
        let width = Preferences.tabWidth
        transformLines(e) { lines in
            lines.map { line in
                let indent = line.prefix { $0 == " " || $0 == "\t" }
                var columns = 0
                for ch in indent { columns = ch == "\t" ? (columns / width + 1) * width : columns + 1 }
                let newIndent = String(repeating: "\t", count: columns / width) + String(repeating: " ", count: columns % width)
                let rest = String(line.dropFirst(indent.count))
                guard !leadingOnly else { return newIndent + rest }
                return newIndent + rest.replacingOccurrences(of: String(repeating: " ", count: width), with: "\t")
            }
        }
    }

    static func eolToSpace(_ e: ScintillaView) {
        transformLines(e) { [$0.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")] }
    }

    static func insertBlankLine(_ e: ScintillaView, above: Bool) {
        let line = e.currentLine
        let eol = eolString(e)
        e.undoGroup {
            if above {
                e.send(SCI_INSERTTEXT, e.lineStart(line), text: eol)
                e.send(SCI_GOTOPOS, e.lineStart(line))
            } else {
                e.send(SCI_INSERTTEXT, e.lineEnd(line), text: eol)
                e.send(SCI_GOTOPOS, e.lineStart(line + 1))
            }
        }
    }

    // MARK: Case

    enum Case { case upper, lower, proper, properBlend, sentence, sentenceBlend, invert, random }

    static func convertCase(_ e: ScintillaView, _ mode: Case) {
        switch mode {
        case .upper: e.send(SCI_UPPERCASE); return
        case .lower: e.send(SCI_LOWERCASE); return
        default: break
        }
        var start = e.selectionStart, end = e.selectionEnd
        if start == end {
            start = e.send(SCI_WORDSTARTPOSITION, start, 1)
            end = e.send(SCI_WORDENDPOSITION, end, 1)
        }
        let text = e.text(from: start, to: end)
        var result = ""
        switch mode {
        case .proper, .properBlend:
            var atWordStart = true
            for ch in text {
                if ch.isLetter {
                    result += atWordStart ? ch.uppercased() : (mode == .proper ? ch.lowercased() : String(ch))
                    atWordStart = false
                } else {
                    result.append(ch)
                    atWordStart = !(ch.isNumber || ch == "'")
                }
            }
        case .sentence, .sentenceBlend:
            var atSentenceStart = true
            for ch in text {
                if ch.isLetter {
                    result += atSentenceStart ? ch.uppercased() : (mode == .sentence ? ch.lowercased() : String(ch))
                    atSentenceStart = false
                } else {
                    result.append(ch)
                    if ".!?".contains(ch) || ch.isNewline { atSentenceStart = true }
                }
            }
        case .invert:
            result = String(text.map { $0.isUppercase ? Character($0.lowercased()) : Character($0.uppercased()) })
        case .random:
            result = String(text.map { Bool.random() ? Character($0.uppercased()) : Character($0.lowercased()) })
        default:
            result = text
        }
        e.undoGroup { e.replace(from: start, to: end, with: result) }
        e.select(start, start + result.utf8.count)
    }

    // MARK: Comments

    enum CommentMode { case toggle, add, remove }

    static func lineComment(_ doc: Document, _ mode: CommentMode) {
        let e = doc.editor
        guard let prefix = doc.language.lineComment else {
            if doc.language.blockComment != nil { blockComment(doc, add: mode != .remove) }
            return
        }
        let range = selectedLines(e, wholeDocument: false)
        let lines = range.map { e.lineText($0) }
        let commented = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .allSatisfy { $0.trimmingCharacters(in: .whitespaces).hasPrefix(prefix.trimmingCharacters(in: .whitespaces)) }
        let remove = mode == .remove || (mode == .toggle && commented)
        let trimmedPrefix = prefix.trimmingCharacters(in: .whitespaces)
        e.undoGroup {
            for line in range.reversed() {
                let text = e.lineText(line)
                guard !text.trimmingCharacters(in: .whitespaces).isEmpty || remove else { continue }
                let indentPos = e.send(SCI_GETLINEINDENTPOSITION, line)
                if remove {
                    let rest = e.text(from: indentPos, to: e.lineEnd(line))
                    if rest.hasPrefix(prefix) {
                        e.replace(from: indentPos, to: indentPos + prefix.utf8.count, with: "")
                    } else if rest.hasPrefix(trimmedPrefix) {
                        var count = trimmedPrefix.utf8.count
                        if rest.dropFirst(trimmedPrefix.count).first == " " { count += 1 }
                        e.replace(from: indentPos, to: indentPos + count, with: "")
                    }
                } else {
                    e.send(SCI_INSERTTEXT, indentPos, text: prefix.hasSuffix(" ") ? prefix : prefix + " ")
                }
            }
        }
    }

    static func blockComment(_ doc: Document, add: Bool) {
        let e = doc.editor
        guard let (open, close) = doc.language.blockComment else { return }
        var start = e.selectionStart, end = e.selectionEnd
        if start == end { start = e.lineStart(e.currentLine); end = e.lineEnd(e.currentLine) }
        let text = e.text(from: start, to: end)
        let result: String
        if add {
            result = open + " " + text + " " + close
        } else {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix(open), trimmed.hasSuffix(close) else { return }
            result = String(trimmed.dropFirst(open.count).dropLast(close.count)).trimmingCharacters(in: .whitespaces)
        }
        e.undoGroup { e.replace(from: start, to: end, with: result) }
        e.select(start, start + result.utf8.count)
    }
}
