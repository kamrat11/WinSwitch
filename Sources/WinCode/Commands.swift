import AppKit
import Scintilla

/// Menu and toolbar commands. The window controller is the window's delegate, so nil-targeted menu items reach it.
extension EditorWindow: NSMenuItemValidation {

    // MARK: File

    @objc func newDocument(_ sender: Any?) { addDocument() }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        if let dir = current?.url?.deletingLastPathComponent() { panel.directoryURL = dir }
        if panel.runModal() == .OK { open(panel.urls) }
    }

    @objc func openRecent(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        open([URL(fileURLWithPath: path)])
    }

    @objc func openAllRecent(_ sender: Any?) {
        open(Preferences.recentFiles.filter { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) })
    }

    @objc func clearRecent(_ sender: Any?) { Preferences.recentFiles = [] }

    @objc func restoreClosed(_ sender: Any?) {
        guard let url = closedFiles.popLast() else { return }
        open([url])
    }

    @objc func revealInFinder(_ sender: Any?) {
        guard let url = current?.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc func openInTerminal(_ sender: Any?) {
        guard let dir = current?.url?.deletingLastPathComponent(),
              let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open([dir], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc func reloadFromDisk(_ sender: Any?) {
        guard let doc = current, doc.url != nil else { return }
        if doc.isModified && !ProcessDialogs.confirm("Are you sure you want to reload the current file and lose the changes made in Notepad++?") { return }
        reload(doc)
    }

    @objc func saveDocument(_ sender: Any?) { if let doc = current { save(doc) } }
    @objc func saveDocumentAs(_ sender: Any?) { if let doc = current { saveAs(doc) } }
    @objc func saveCopyAs(_ sender: Any?) { if let doc = current { saveAs(doc, copy: true) } }

    @objc func saveAll(_ sender: Any?) {
        for doc in documents where doc.isModified {
            if !save(doc) { break }
        }
    }

    @objc func renameFile(_ sender: Any?) {
        guard let doc = current else { return }
        guard let name = ProcessDialogs.ask("Rename", "New name:", value: doc.name), !name.isEmpty, name != doc.name else { return }
        guard let url = doc.url else {
            // An untitled tab is renamed by saving it.
            saveAs(doc)
            return
        }
        let target = url.deletingLastPathComponent().appendingPathComponent(name)
        do {
            try FileManager.default.moveItem(at: url, to: target)
            doc.url = target
            doc.fileDate = Document.modificationDate(target)
            doc.setLanguage(Language.detect(url: target, firstLine: doc.editor.lineText(0)))
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @objc func moveToTrash(_ sender: Any?) {
        guard let doc = current, let url = doc.url else { return }
        guard ProcessDialogs.confirm("Are you sure you want to move \"\(url.path)\" to the Trash?") else { return }
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            doc.editor.send(SCI_SETSAVEPOINT)
            closeDocuments { $1 === doc }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @objc func closeTab(_ sender: Any?) { close(at: currentIndex) }
    @objc func closeAll(_ sender: Any?) { closeDocuments { _, _ in true } }
    @objc func closeAllButThis(_ sender: Any?) { let keep = current; closeDocuments { $1 !== keep } }
    @objc func closeAllLeft(_ sender: Any?) { let i = currentIndex; closeDocuments { index, _ in index < i } }
    @objc func closeAllRight(_ sender: Any?) { let i = currentIndex; closeDocuments { index, _ in index > i } }
    @objc func closeAllUnchanged(_ sender: Any?) { closeDocuments { !$1.isModified } }

    @objc func printDocument(_ sender: Any?) {
        guard let doc = current else { return }
        let info = NSPrintInfo.shared
        info.horizontalPagination = .fit
        info.isVerticallyCentered = false
        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        view.font = NSFont(name: Preferences.fontName, size: 9) ?? .monospacedSystemFont(ofSize: 9, weight: .regular)
        view.string = doc.editor.text.replacingOccurrences(of: "\r\n", with: "\n")
        view.textContainer?.widthTracksTextView = true
        view.sizeToFit()
        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.jobTitle = doc.name
        operation.runModal(for: window!, delegate: nil, didRun: nil, contextInfo: nil)
    }

    // MARK: Edit

    @objc func beginEndSelect(_ sender: Any?) { beginEndSelect(rectangular: false) }
    @objc func beginEndSelectColumn(_ sender: Any?) { beginEndSelect(rectangular: true) }

    private static var selectAnchor: Int?

    private func beginEndSelect(rectangular: Bool) {
        guard let e = editor else { return }
        if let anchor = Self.selectAnchor {
            let caret = e.currentPos
            if rectangular {
                e.send(SCI_SETSELECTIONMODE, Int(SC_SEL_RECTANGLE))
                e.send(SCI_SETRECTANGULARSELECTIONANCHOR, anchor)
                e.send(SCI_SETRECTANGULARSELECTIONCARET, caret)
            } else {
                e.send(SCI_SETSEL, anchor, caret)
            }
            Self.selectAnchor = nil
        } else {
            Self.selectAnchor = e.currentPos
        }
    }

    @objc func insertDateTime(_ sender: NSMenuItem) {
        let formatter = DateFormatter()
        switch sender.tag {
        case 0: formatter.dateStyle = .short; formatter.timeStyle = .short
        case 1: formatter.dateStyle = .full; formatter.timeStyle = .short
        default: formatter.dateFormat = UserDefaults.standard.string(forKey: "dateTimeFormat") ?? "yyyy-MM-dd HH:mm:ss"
        }
        editor?.send(SCI_REPLACESEL, 0, text: formatter.string(from: Date()))
    }

    @objc func copyPathInfo(_ sender: NSMenuItem) {
        guard let doc = current else { return }
        let value: String
        switch sender.tag {
        case 0: value = doc.url?.path ?? doc.name
        case 1: value = doc.name
        case 2: value = doc.url?.deletingLastPathComponent().path ?? ""
        case 3: value = documents.map(\.name).joined(separator: "\n")
        default: value = documents.map { $0.url?.path ?? $0.name }.joined(separator: "\n")
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    @objc func changeIndent(_ sender: NSMenuItem) { editor?.send(sender.tag > 0 ? SCI_TAB : SCI_BACKTAB) }

    @objc func convertCase(_ sender: NSMenuItem) {
        guard let e = editor else { return }
        let modes: [Editing.Case] = [.upper, .lower, .proper, .properBlend, .sentence, .sentenceBlend, .invert, .random]
        Editing.convertCase(e, modes[sender.tag])
    }

    @objc func lineOperation(_ sender: NSMenuItem) {
        guard let e = editor else { return }
        switch sender.tag {
        case 0: e.send(SCI_SELECTIONDUPLICATE)
        case 1: Editing.removeDuplicateLines(e, consecutiveOnly: false)
        case 2: Editing.removeDuplicateLines(e, consecutiveOnly: true)
        case 3:
            e.send(SCI_TARGETFROMSELECTION)
            e.send(SCI_LINESSPLIT, 0)
        case 4:
            let range = Editing.selectedLines(e, wholeDocument: false)
            e.send(SCI_SETTARGETRANGE, e.lineStart(range.lowerBound), e.lineEnd(range.upperBound == range.lowerBound ? range.upperBound + 1 : range.upperBound))
            e.send(SCI_LINESJOIN)
        case 5: e.send(SCI_MOVESELECTEDLINESUP)
        case 6: e.send(SCI_MOVESELECTEDLINESDOWN)
        case 7: e.send(SCI_LINEDELETE)
        case 8: Editing.removeEmptyLines(e, blankToo: false)
        case 9: Editing.removeEmptyLines(e, blankToo: true)
        case 10: Editing.insertBlankLine(e, above: true)
        case 11: Editing.insertBlankLine(e, above: false)
        case 12: Editing.transformLines(e) { $0.reversed() }
        case 13: Editing.sortLines(e, descending: false)
        case 14: Editing.sortLines(e, descending: true)
        case 15: Editing.sortLines(e, descending: false, caseInsensitive: true)
        case 16: Editing.sortLines(e, descending: true, caseInsensitive: true)
        case 17: Editing.sortLines(e, descending: false, numeric: true)
        case 18: Editing.sortLines(e, descending: true, numeric: true)
        default: Editing.transformLines(e) { $0.shuffled() }
        }
    }

    @objc func comment(_ sender: NSMenuItem) {
        guard let doc = current else { return }
        switch sender.tag {
        case 0: Editing.lineComment(doc, .toggle)
        case 1: Editing.lineComment(doc, .add)
        case 2: Editing.lineComment(doc, .remove)
        case 3: Editing.blockComment(doc, add: true)
        default: Editing.blockComment(doc, add: false)
        }
    }

    @objc func wordCompletion(_ sender: Any?) { if let doc = current { Editing.showCompletion(doc, minimum: 1) } }

    @objc func convertEOL(_ sender: NSMenuItem) {
        guard let doc = current, let raw = sender.representedObject as? String, let eol = EOL(rawValue: raw) else { return }
        doc.eol = eol
        doc.editor.send(SCI_SETEOLMODE, eol.mode)
        doc.editor.send(SCI_CONVERTEOLS, eol.mode)
        documentChanged(doc)
    }

    @objc func blankOperation(_ sender: NSMenuItem) {
        guard let e = editor else { return }
        switch sender.tag {
        case 0: Editing.trim(e, leading: false, trailing: true)
        case 1: Editing.trim(e, leading: true, trailing: false)
        case 2: Editing.trim(e, leading: true, trailing: true)
        case 3: Editing.eolToSpace(e)
        case 4: Editing.tabsToSpaces(e)
        case 5: Editing.spacesToTabs(e, leadingOnly: false)
        default: Editing.spacesToTabs(e, leadingOnly: true)
        }
    }

    @objc func columnEditor(_ sender: Any?) {
        guard let e = editor else { return }
        ColumnEditor.run(e, in: window)
    }

    @objc func toggleReadOnly(_ sender: Any?) { current?.readOnly.toggle() }

    // MARK: Search

    @objc func showFind(_ sender: Any?) { FindDialog.shared.show(.find, owner: self) }
    @objc func showReplace(_ sender: Any?) { FindDialog.shared.show(.replace, owner: self) }
    @objc func showFindInFiles(_ sender: Any?) { FindDialog.shared.show(.findInFiles, owner: self) }
    @objc func showMark(_ sender: Any?) { FindDialog.shared.show(.mark, owner: self) }

    @objc func findNext(_ sender: Any?) { find(backward: false) }
    @objc func findPrevious(_ sender: Any?) { find(backward: true) }

    private func find(backward: Bool) {
        guard let e = editor else { return }
        var o = Search.options
        if o.text.isEmpty { showFind(nil); return }
        o.backward = backward
        if !Search.findNext(e, o) { NSSound.beep() }
    }

    @objc func selectAndFindNext(_ sender: Any?) { selectAndFind(backward: false) }
    @objc func selectAndFindPrevious(_ sender: Any?) { selectAndFind(backward: true) }

    private func selectAndFind(backward: Bool) {
        guard let e = editor else { return }
        var word = e.selectedText
        if word.isEmpty {
            let pos = e.currentPos
            let start = e.send(SCI_WORDSTARTPOSITION, pos, 1), end = e.send(SCI_WORDENDPOSITION, pos, 1)
            word = e.text(from: start, to: end)
            e.select(start, end)
        }
        guard !word.isEmpty else { return }
        var o = SearchOptions()
        o.text = word
        o.matchCase = true
        o.backward = backward
        Search.options = o
        Search.findNext(e, o)
    }

    @objc func goToLine(_ sender: Any?) {
        guard let e = editor else { return }
        let prompt = "You are here: \(e.currentLine + 1)\nYou want to go to (1 - \(e.lineCount)):"
        guard let answer = ProcessDialogs.ask("Go To...", prompt), let line = Int(answer.trimmingCharacters(in: .whitespaces)) else { return }
        e.goTo(line: max(0, min(line - 1, e.lineCount - 1)))
    }

    @objc func goToMatchingBrace(_ sender: Any?) {
        guard let e = editor else { return }
        var pos = e.currentPos
        var match = e.send(SCI_BRACEMATCH, pos, 0)
        if match < 0, pos > 0 { pos -= 1; match = e.send(SCI_BRACEMATCH, pos, 0) }
        if match >= 0 { e.send(SCI_GOTOPOS, match) }
    }

    @objc func selectBetweenBraces(_ sender: Any?) {
        guard let e = editor else { return }
        var pos = e.currentPos
        // Walk back to the nearest unmatched opening brace.
        while pos > 0 {
            pos -= 1
            let ch = UInt8(truncatingIfNeeded: e.send(SCI_GETCHARAT, pos))
            guard "([{".utf8.contains(ch) else { continue }
            let match = e.send(SCI_BRACEMATCH, pos, 0)
            if match >= e.currentPos { e.select(pos + 1, match); return }
        }
    }

    @objc func styleToken(_ sender: NSMenuItem) {
        guard let e = editor else { return }
        var text = e.selectedText
        var o = SearchOptions()
        o.matchCase = true
        if text.isEmpty {
            let pos = e.currentPos
            text = e.text(from: e.send(SCI_WORDSTARTPOSITION, pos, 1), to: e.send(SCI_WORDENDPOSITION, pos, 1))
            o.wholeWord = true
        }
        guard !text.isEmpty else { return }
        o.text = text
        let indicator = Indicator.tokenStyles[sender.tag]
        e.send(SCI_SETINDICATORCURRENT, Int(indicator))
        for (start, end) in Search.findAll(e, o) { e.send(SCI_INDICATORFILLRANGE, start, end - start) }
    }

    @objc func clearTokenStyle(_ sender: NSMenuItem) {
        guard let e = editor else { return }
        let indicators = sender.tag < 0 ? Indicator.tokenStyles + [Indicator.findMark] : [Indicator.tokenStyles[sender.tag]]
        for indicator in indicators {
            e.send(SCI_SETINDICATORCURRENT, Int(indicator))
            e.send(SCI_INDICATORCLEARRANGE, 0, e.length)
        }
    }

    @objc func toggleBookmark(_ sender: Any?) { if let e = editor { Editing.toggleBookmark(e, line: e.currentLine) } }
    @objc func nextBookmark(_ sender: Any?) { if let e = editor { Editing.nextBookmark(e, forward: true) } }
    @objc func previousBookmark(_ sender: Any?) { if let e = editor { Editing.nextBookmark(e, forward: false) } }

    @objc func bookmarkOperation(_ sender: NSMenuItem) {
        guard let e = editor else { return }
        let lines = Editing.bookmarkedLines(e)
        let eol = Editing.eolString(e)
        func copyLines() {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(lines.map { e.lineText($0) }.joined(separator: eol) + eol, forType: .string)
        }
        func deleteLines(_ targets: [Int]) {
            e.undoGroup {
                for line in targets.reversed() {
                    e.send(SCI_MARKERDELETE, line, Int(Marker.bookmark))
                    let end = line + 1 < e.lineCount ? e.lineStart(line + 1) : e.lineEnd(line)
                    e.replace(from: e.lineStart(line), to: end, with: "")
                }
            }
        }
        switch sender.tag {
        case 0: e.send(SCI_MARKERDELETEALL, Int(Marker.bookmark))
        case 1: copyLines(); deleteLines(lines)
        case 2: copyLines()
        case 3: deleteLines(lines)
        case 4: deleteLines((0..<e.lineCount).filter { !lines.contains($0) })
        default:
            for line in 0..<e.lineCount { Editing.toggleBookmark(e, line: line) }
        }
    }

    // MARK: View

    @objc func toggleAlwaysOnTop(_ sender: Any?) {
        Preferences.alwaysOnTop.toggle()
        window?.level = Preferences.alwaysOnTop ? .floating : .normal
    }

    private func togglePreference(_ keyPath: ReferenceWritableKeyPath<PreferenceBox, Bool>) {
        PreferenceBox.shared[keyPath: keyPath].toggle()
        documents.forEach { $0.applyPreferences() }
        updatePanels()
    }

    @objc func toggleWhitespace(_ sender: Any?) { togglePreference(\.showWhitespace) }
    @objc func toggleEOL(_ sender: Any?) { togglePreference(\.showEOL) }
    @objc func toggleIndentGuides(_ sender: Any?) { togglePreference(\.showIndentGuides) }
    @objc func toggleWrapSymbol(_ sender: Any?) { togglePreference(\.showWrapSymbol) }
    @objc func toggleWordWrap(_ sender: Any?) { togglePreference(\.wordWrap) }
    @objc func toggleLineNumbers(_ sender: Any?) { togglePreference(\.showLineNumbers) }
    @objc func toggleFunctionList(_ sender: Any?) { togglePreference(\.showFunctionList) }
    @objc func toggleDocumentMap(_ sender: Any?) { togglePreference(\.showDocumentMap) }
    @objc func toggleToolbar(_ sender: Any?) { togglePreference(\.showToolbar) }
    @objc func toggleStatusBar(_ sender: Any?) { togglePreference(\.showStatusBar) }
    @objc func toggleResults(_ sender: Any?) { showResults(results.isHidden) }

    @objc func toggleAllCharacters(_ sender: Any?) {
        let on = !(Preferences.showWhitespace && Preferences.showEOL)
        Preferences.showWhitespace = on
        Preferences.showEOL = on
        documents.forEach { $0.applyPreferences() }
    }

    @objc func zoomIn(_ sender: Any?) { editor?.send(SCI_ZOOMIN) }
    @objc func zoomOut(_ sender: Any?) { editor?.send(SCI_ZOOMOUT) }
    @objc func zoomReset(_ sender: Any?) { editor?.send(SCI_SETZOOM, 0) }

    @objc func foldAll(_ sender: Any?) { editor?.send(SCI_FOLDALL, Int(SC_FOLDACTION_CONTRACT)) }
    @objc func unfoldAll(_ sender: Any?) { editor?.send(SCI_FOLDALL, Int(SC_FOLDACTION_EXPAND)) }

    /// The fold header of the caret's line or the block it is in.
    private func foldHeader(_ e: ScintillaView) -> Int {
        let line = e.currentLine
        if e.send(SCI_GETFOLDLEVEL, line) & Int(SC_FOLDLEVELHEADERFLAG) != 0 { return line }
        return e.send(SCI_GETFOLDPARENT, line)
    }

    @objc func foldCurrent(_ sender: Any?) {
        guard let e = editor else { return }
        let header = foldHeader(e)
        if header >= 0 { e.send(SCI_FOLDLINE, header, Int(SC_FOLDACTION_CONTRACT)) }
    }

    @objc func unfoldCurrent(_ sender: Any?) {
        guard let e = editor else { return }
        let header = foldHeader(e)
        if header >= 0 { e.send(SCI_FOLDLINE, header, Int(SC_FOLDACTION_EXPAND)) }
    }

    private func foldLevel(_ level: Int, contract: Bool) {
        guard let e = editor else { return }
        for line in 0..<e.lineCount {
            let flags = e.send(SCI_GETFOLDLEVEL, line)
            guard flags & Int(SC_FOLDLEVELHEADERFLAG) != 0 else { continue }
            if (flags & Int(SC_FOLDLEVELNUMBERMASK)) - Int(SC_FOLDLEVELBASE) == level - 1 {
                e.send(SCI_FOLDLINE, line, Int(contract ? SC_FOLDACTION_CONTRACT : SC_FOLDACTION_EXPAND))
            }
        }
    }

    @objc func foldLevel(_ sender: NSMenuItem) { foldLevel(sender.tag, contract: true) }
    @objc func unfoldLevel(_ sender: NSMenuItem) { foldLevel(sender.tag, contract: false) }

    @objc func summary(_ sender: Any?) {
        guard let doc = current else { return }
        let e = doc.editor
        let text = e.text
        let words = text.split { $0.isWhitespace || $0.isPunctuation }.count
        let characters = text.unicodeScalars.filter { $0 != "\r" && $0 != "\n" }.count
        var info = ""
        if let url = doc.url {
            let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .medium
            info += "Full file path: \(url.path)\n"
            if let d = values?.creationDate { info += "Created: \(f.string(from: d))\n" }
            if let d = values?.contentModificationDate { info += "Modified: \(f.string(from: d))\n" }
            info += "\n"
        }
        info += "Characters (without line endings): \(characters)\nWords: \(words)\nLines: \(e.lineCount)\n"
        info += "Document length: \(e.length)\n"
        info += "\(e.send(SCI_COUNTCHARACTERS, e.selectionStart, e.selectionEnd)) selected characters (\(e.selectionEnd - e.selectionStart) bytes) in \(e.send(SCI_GETSELECTIONS)) ranges"
        let alert = NSAlert()
        alert.messageText = "Summary"
        alert.informativeText = info
        alert.runModal()
    }

    // MARK: Encoding and language

    /// "Encode in": read the file again as this encoding (a new document just remembers it).
    @objc func encodeIn(_ sender: NSMenuItem) {
        guard let doc = current, let raw = sender.representedObject as? String, let encoding = TextEncoding(rawValue: raw) else { return }
        if doc.url != nil && !doc.isModified {
            reload(doc, encoding: encoding)
        } else {
            doc.encoding = encoding
            documentChanged(doc)
        }
    }

    /// "Convert to": keep the text, save it in this encoding next time.
    @objc func convertTo(_ sender: NSMenuItem) {
        guard let doc = current, let raw = sender.representedObject as? String, let encoding = TextEncoding(rawValue: raw) else { return }
        guard encoding.encode(doc.editor.text) != nil else {
            let alert = NSAlert()
            alert.messageText = "The text contains characters that \(encoding.title) can't store."
            alert.runModal()
            return
        }
        doc.encoding = encoding
        // Mark the document modified so the conversion gets saved.
        doc.editor.undoGroup {
            doc.editor.send(SCI_INSERTTEXT, 0, text: " ")
            doc.editor.send(SCI_DELETERANGE, 0, 1)
        }
        documentChanged(doc)
    }

    @objc func setLanguage(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, let language = Language.named(name) else { return }
        current?.setLanguage(language)
        sidePanel.reload()
    }

    // MARK: Settings

    @objc func showPreferences(_ sender: Any?) { PreferencesWindow.shared.show(owner: self) }

    @objc func setTheme(_ sender: NSMenuItem) {
        guard let theme = sender.representedObject as? String else { return }
        Preferences.theme = theme
        applyPreferencesToAll()
    }

    func applyPreferencesToAll() {
        documents.forEach { $0.applyPreferences() }
        updatePanels()
    }

    @objc func chooseFont(_ sender: Any?) {
        let manager = NSFontManager.shared
        manager.target = self
        manager.setSelectedFont(NSFont(name: Preferences.fontName, size: CGFloat(Preferences.fontSize)) ?? .monospacedSystemFont(ofSize: 12, weight: .regular), isMultiple: false)
        manager.orderFrontFontPanel(self)
    }

    @objc func changeFont(_ sender: NSFontManager?) {
        guard let manager = sender else { return }
        let font = manager.convert(NSFont(name: Preferences.fontName, size: CGFloat(Preferences.fontSize)) ?? .systemFont(ofSize: 12))
        Preferences.fontName = font.familyName ?? font.fontName
        Preferences.fontSize = Int(font.pointSize.rounded())
        applyPreferencesToAll()
    }

    // MARK: Macro

    @objc func startRecording(_ sender: Any?) { macro.start() }
    @objc func stopRecording(_ sender: Any?) { macro.stop() }
    @objc func playMacro(_ sender: Any?) { macro.play() }

    @objc func saveMacro(_ sender: Any?) {
        guard !macro.steps.isEmpty, let name = ProcessDialogs.ask("Save Macro", "Name:"), !name.isEmpty else { return }
        macro.saveCurrent(named: name)
    }

    @objc func playSavedMacro(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        macro.play(MacroRecorder.saved(name))
    }

    @objc func deleteMacro(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        var macros = Preferences.savedMacros
        macros[name] = nil
        Preferences.savedMacros = macros
    }

    @objc func runMacroMultiple(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Run a Macro Multiple Times"
        let names = ["Current recorded macro"] + Preferences.savedMacros.keys.sorted()
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26))
        popup.addItems(withTitles: names)
        let times = NSButton(radioButtonWithTitle: "Run", target: nil, action: nil)
        let untilEnd = NSButton(radioButtonWithTitle: "Run until the end of file", target: nil, action: nil)
        times.state = .on
        let count = NSTextField(string: "1")
        count.widthAnchor.constraint(equalToConstant: 60).isActive = true
        let row = NSStackView(views: [times, count, NSTextField(labelWithString: "times")])
        let stack = NSStackView(views: [popup, row, untilEnd])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.frame = NSRect(x: 0, y: 0, width: 280, height: 90)
        alert.accessoryView = stack
        alert.addButton(withTitle: "Run")
        alert.addButton(withTitle: "Cancel")
        // The two radio buttons sit in different stacks, so keep them exclusive by hand.
        let toggle = RadioPair(times, untilEnd)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        _ = toggle
        let steps = popup.indexOfSelectedItem == 0 ? nil : MacroRecorder.saved(names[popup.indexOfSelectedItem])
        macro.play(steps, times: max(1, count.integerValue), untilEnd: untilEnd.state == .on)
    }

    @objc func trimAndSave(_ sender: Any?) {
        guard let doc = current else { return }
        let pos = doc.editor.currentPos
        let start = doc.editor.selectionStart
        doc.editor.select(start, start)
        Editing.trim(doc.editor, leading: false, trailing: true)
        doc.editor.send(SCI_GOTOPOS, min(pos, doc.editor.length))
        save(doc)
    }

    // MARK: Run

    @objc func runCommand(_ sender: Any?) {
        let hint = "Variables: $(FULL_CURRENT_PATH) $(CURRENT_DIRECTORY) $(FILE_NAME) $(NAME_PART) $(EXT_PART) $(CURRENT_WORD) $(CURRENT_LINE)"
        guard let command = ProcessDialogs.ask("Run...", "The program to run (in zsh). Its output opens in a new tab.\n" + hint,
                                               value: Preferences.runCommands.first ?? "", width: 420), !command.isEmpty else { return }
        Preferences.runCommands = [command] + Preferences.runCommands.filter { $0 != command }
        run(command)
    }

    @objc func runSavedCommand(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? String else { return }
        run(command)
    }

    private func run(_ template: String) {
        let url = current?.url
        var command = template
        let word: String = {
            guard let e = editor else { return "" }
            let pos = e.currentPos
            return e.selectedText.isEmpty ? e.text(from: e.send(SCI_WORDSTARTPOSITION, pos, 1), to: e.send(SCI_WORDENDPOSITION, pos, 1)) : e.selectedText
        }()
        let values = [
            "FULL_CURRENT_PATH": url?.path ?? "", "CURRENT_DIRECTORY": url?.deletingLastPathComponent().path ?? "",
            "FILE_NAME": url?.lastPathComponent ?? "", "NAME_PART": url?.deletingPathExtension().lastPathComponent ?? "",
            "EXT_PART": url.map { "." + $0.pathExtension } ?? "", "CURRENT_WORD": word, "CURRENT_LINE": "\((editor?.currentLine ?? 0) + 1)",
        ]
        for (key, value) in values { command = command.replacingOccurrences(of: "$(\(key))", with: value) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        if let dir = url?.deletingLastPathComponent() { process.currentDirectoryURL = dir }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.terminationHandler = { finished in
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let status = finished.terminationStatus
            DispatchQueue.main.async {
                guard !output.isEmpty || status != 0 else { return }
                let doc = self.addDocument()
                doc.editor.text = "> \(command)\n\n" + output + (status != 0 ? "\n[exit code \(status)]\n" : "")
                doc.editor.send(SCI_SETSAVEPOINT)
            }
        }
        do { try process.run() } catch { NSAlert(error: error).runModal() }
    }

    @objc func launchInBrowser(_ sender: NSMenuItem) {
        guard let doc = current, let bundle = sender.representedObject as? String,
              let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return }
        if doc.isModified, doc.url != nil { save(doc) }
        guard let url = doc.url else { return }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc func searchOnInternet(_ sender: Any?) {
        guard let e = editor else { return }
        var text = e.selectedText
        if text.isEmpty { let p = e.currentPos; text = e.text(from: e.send(SCI_WORDSTARTPOSITION, p, 1), to: e.send(SCI_WORDENDPOSITION, p, 1)) }
        guard !text.isEmpty, let query = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://www.google.com/search?q=\(query)") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Window menu

    @objc func nextTab(_ sender: Any?) { select((currentIndex + 1) % max(1, documents.count)) }
    @objc func previousTab(_ sender: Any?) { select((currentIndex - 1 + documents.count) % max(1, documents.count)) }
    @objc func selectTabFromMenu(_ sender: NSMenuItem) { select(sender.tag) }

    @objc func sortTabs(_ sender: NSMenuItem) {
        let doc = current
        let key: (Document) -> String
        switch sender.tag / 2 {
        case 0: key = { $0.name.lowercased() }
        case 1: key = { ($0.url?.path ?? $0.name).lowercased() }
        default: key = { ($0.url?.pathExtension ?? "").lowercased() + $0.name.lowercased() }
        }
        var sorted = documents.sorted { key($0) < key($1) }
        if sender.tag % 2 == 1 { sorted.reverse() }
        reorder(sorted)
        if let doc, let index = documents.firstIndex(where: { $0 === doc }) { select(index) }
    }

    // MARK: Validation

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let doc = current
        switch item.action {
        case #selector(toggleAlwaysOnTop(_:)): item.state = Preferences.alwaysOnTop ? .on : .off
        case #selector(toggleWhitespace(_:)): item.state = Preferences.showWhitespace ? .on : .off
        case #selector(toggleEOL(_:)): item.state = Preferences.showEOL ? .on : .off
        case #selector(toggleAllCharacters(_:)): item.state = Preferences.showWhitespace && Preferences.showEOL ? .on : .off
        case #selector(toggleIndentGuides(_:)): item.state = Preferences.showIndentGuides ? .on : .off
        case #selector(toggleWrapSymbol(_:)): item.state = Preferences.showWrapSymbol ? .on : .off
        case #selector(toggleWordWrap(_:)): item.state = Preferences.wordWrap ? .on : .off
        case #selector(toggleLineNumbers(_:)): item.state = Preferences.showLineNumbers ? .on : .off
        case #selector(toggleFunctionList(_:)): item.state = Preferences.showFunctionList ? .on : .off
        case #selector(toggleDocumentMap(_:)): item.state = Preferences.showDocumentMap ? .on : .off
        case #selector(toggleToolbar(_:)): item.state = Preferences.showToolbar ? .on : .off
        case #selector(toggleStatusBar(_:)): item.state = Preferences.showStatusBar ? .on : .off
        case #selector(toggleResults(_:)): item.state = results.isHidden ? .off : .on
        case #selector(toggleReadOnly(_:)):
            item.state = doc?.readOnly == true ? .on : .off
            return doc?.url.map { FileManager.default.isWritableFile(atPath: $0.path) } ?? true
        case #selector(setTheme(_:)): item.state = Preferences.theme == item.representedObject as? String ? .on : .off
        case #selector(setLanguage(_:)): item.state = doc?.language.name == item.representedObject as? String ? .on : .off
        case #selector(encodeIn(_:)): item.state = doc?.encoding.rawValue == item.representedObject as? String ? .on : .off
        case #selector(convertEOL(_:)): item.state = doc?.eol.rawValue == item.representedObject as? String ? .on : .off
        case #selector(reloadFromDisk(_:)), #selector(revealInFinder(_:)), #selector(openInTerminal(_:)),
             #selector(moveToTrash(_:)), #selector(launchInBrowser(_:)):
            return doc?.url != nil
        case #selector(restoreClosed(_:)): return !closedFiles.isEmpty
        case #selector(startRecording(_:)): return !macro.isRecording
        case #selector(stopRecording(_:)): return macro.isRecording
        case #selector(playMacro(_:)), #selector(saveMacro(_:)): return !macro.isRecording && !macro.steps.isEmpty
        case #selector(comment(_:)):
            return item.tag < 3 ? doc?.language.lineComment != nil || doc?.language.blockComment != nil : doc?.language.blockComment != nil
        default: break
        }
        return true
    }
}

/// Settings stored in Preferences, as key paths for the View toggles.
@MainActor
final class PreferenceBox {
    static let shared = PreferenceBox()
    var showWhitespace: Bool { get { Preferences.showWhitespace } set { Preferences.showWhitespace = newValue } }
    var showEOL: Bool { get { Preferences.showEOL } set { Preferences.showEOL = newValue } }
    var showIndentGuides: Bool { get { Preferences.showIndentGuides } set { Preferences.showIndentGuides = newValue } }
    var showWrapSymbol: Bool { get { Preferences.showWrapSymbol } set { Preferences.showWrapSymbol = newValue } }
    var wordWrap: Bool { get { Preferences.wordWrap } set { Preferences.wordWrap = newValue } }
    var showLineNumbers: Bool { get { Preferences.showLineNumbers } set { Preferences.showLineNumbers = newValue } }
    var showFunctionList: Bool { get { Preferences.showFunctionList } set { Preferences.showFunctionList = newValue } }
    var showDocumentMap: Bool { get { Preferences.showDocumentMap } set { Preferences.showDocumentMap = newValue } }
    var showToolbar: Bool { get { Preferences.showToolbar } set { Preferences.showToolbar = newValue } }
    var showStatusBar: Bool { get { Preferences.showStatusBar } set { Preferences.showStatusBar = newValue } }
}

/// Keeps two radio buttons in different containers mutually exclusive.
@MainActor
final class RadioPair: NSObject {
    private let a: NSButton, b: NSButton
    init(_ a: NSButton, _ b: NSButton) {
        self.a = a
        self.b = b
        super.init()
        for button in [a, b] {
            button.target = self
            button.action = #selector(clicked(_:))
        }
    }
    @objc private func clicked(_ sender: NSButton) {
        a.state = sender === a ? .on : .off
        b.state = sender === b ? .on : .off
    }
}
