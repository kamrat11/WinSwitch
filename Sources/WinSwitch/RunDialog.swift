import AppKit

/// Windows-style Run box (Win+R): type a program, file, folder, web address or command and press Enter.
@MainActor
final class RunDialog: NSObject, NSWindowDelegate, NSComboBoxDelegate {
    static let shared = RunDialog()

    private var panel: NSPanel?
    private let field = NSComboBox()
    private let message = NSTextField(labelWithString: "")
    private let historyKey = "runHistory"

    private var history: [String] {
        get { UserDefaults.standard.stringArray(forKey: historyKey) ?? [] }
        set { UserDefaults.standard.set(Array(newValue.prefix(25)), forKey: historyKey) }
    }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        field.removeAllItems()
        field.addItems(withObjectValues: history)
        field.stringValue = history.first ?? ""
        message.stringValue = "Type the name of a program, folder, document or website, and it will open."
        message.textColor = .secondaryLabelColor

        // Bottom-left of the screen with the mouse, like Windows.
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let f = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: f.minX + 12, y: f.minY + 12))
        }
        Windows.focusOwn(panel)
        panel.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 190),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "Run"
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.delegate = self

        let icon = NSImageView(image: NSImage(systemSymbolName: "play.rectangle", accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 28, weight: .regular)

        message.lineBreakMode = .byWordWrapping
        message.maximumNumberOfLines = 2
        message.preferredMaxLayoutWidth = 360

        let label = NSTextField(labelWithString: "Open:")
        field.completes = true
        field.numberOfVisibleItems = 12
        field.target = self
        field.action = #selector(ok)
        field.delegate = self

        let okButton = NSButton(title: "OK", target: self, action: #selector(ok))
        okButton.keyEquivalent = "\r"
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelButton.keyEquivalent = "\u{1b}"
        let browseButton = NSButton(title: "Browse…", target: self, action: #selector(browse))

        let top = NSStackView(views: [icon, message])
        top.alignment = .top
        let middle = NSStackView(views: [label, field])
        for button in [okButton, cancelButton, browseButton] {
            button.controlSize = .large
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 84).isActive = true
        }
        let buttons = NSStackView(views: [NSView(), okButton, cancelButton, browseButton])
        // Message and Open field at the top, buttons pinned to the bottom edge like the Windows Run box.
        let stack = NSStackView()
        stack.setViews([top, middle], in: .top)
        stack.setViews([buttons], in: .bottom)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 20
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = NSView()
        panel.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor),
            stack.topAnchor.constraint(equalTo: panel.contentView!.topAnchor),
            stack.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor),
            middle.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 330),
            panel.contentView!.heightAnchor.constraint(greaterThanOrEqualToConstant: 190), // the height of the Windows Run box
        ])
        return panel
    }

    @objc private func ok() {
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let error = RunCommand.run(text) {
            message.stringValue = error
            message.textColor = .systemRed
            return
        }
        history = [text] + history.filter { $0 != text }
        panel?.orderOut(nil)
    }

    @objc private func cancel() { panel?.orderOut(nil) }

    @objc private func browse() {
        let open = NSOpenPanel()
        open.canChooseFiles = true
        open.canChooseDirectories = true
        open.directoryURL = URL(fileURLWithPath: "/Applications")
        if open.runModal() == .OK, let url = open.url {
            field.stringValue = url.path.contains(" ") ? "\"\(url.path)\"" : url.path
        }
        panel?.makeKeyAndOrderFront(nil)
    }
}

/// Works out what the typed text means and opens it.
enum RunCommand {
    /// Windows names mapped to their Mac counterparts.
    static let aliases: [String: String] = [
        // "A|B": the first app found (our Windows-style apps, then the macOS ones).
        "notepad": "Notepad|TextEdit",
        "notepad++": "Notepad++|TextEdit",
        "npp": "Notepad++|TextEdit",
        "write": "TextEdit",
        "wordpad": "TextEdit",
        "calc": "Calculator",
        "activitymonitor": "Activity Monitor",
        "control": "System Settings",
        "mspaint": "MS Paint|Preview",
        "pbrush": "MS Paint|Preview",
        "paint": "MS Paint|Preview",
        "snippingtool": "Screenshot",
        "charmap": "Character Viewer",
        "msedge": "Microsoft Edge",
        "chrome": "Google Chrome",
        "code": "Visual Studio Code",
        "winword": "Microsoft Word",
        "excel": "Microsoft Excel",
        "powerpnt": "Microsoft PowerPoint",
        "outlook": "Microsoft Outlook",
        "mstsc": "Windows App",
    ]
    static let terminalWords: Set<String> = ["cmd", "terminal", "powershell", "pwsh", "wt", "shell", "bash", "zsh"]

    /// Returns an error message, or nil when something was opened.
    @MainActor
    static func run(_ text: String) -> String? {
        let words = split(text)
        guard let first = words.first else { return nil }
        let lower = first.lowercased().replacingOccurrences(of: ".exe", with: "")
        let rest = Array(words.dropFirst())

        // cmd / terminal [folder]: a new Terminal window, optionally in that folder.
        if terminalWords.contains(lower) {
            let folder = rest.first.map(expand).flatMap { isDirectory($0) ? $0 : nil }
            return openTerminal(cd: folder, command: folder == nil && !rest.isEmpty ? rest.joined(separator: " ") : nil)
        }

        // taskmgr: our Task Manager.
        if lower == "taskmgr" || lower == "taskmanager" {
            TaskManager.show()
            return nil
        }

        // explorer [folder]: our File Explorer.
        if lower == "explorer" || lower == "files" {
            let target = rest.first.map(expand) ?? NSHomeDirectory()
            guard isDirectory(target) else { return "Can't find the folder '\(rest.first ?? "")'." }
            Explorer.openWindow(at: URL(fileURLWithPath: target))
            return nil
        }

        // Web addresses.
        if let url = webURL(text) {
            NSWorkspace.shared.open(url)
            return nil
        }

        // A file or folder path: open with its default app.
        let path = expand(words.count == 1 ? first : text)
        if FileManager.default.fileExists(atPath: path) {
            // Folders open in our Explorer, like Windows; files and app bundles in their default app.
            if isDirectory(path) && !NSWorkspace.shared.isFilePackage(atPath: path) {
                Explorer.openWindow(at: URL(fileURLWithPath: path))
            } else {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            }
            return nil
        }

        // An app, optionally followed by files to open with it ("notepad ~/notes.txt").
        let candidates = (aliases[lower] ?? first).split(separator: "|").map(String.init)
        if let app = candidates.lazy.compactMap(findApp).first {
            let files = rest.map { URL(fileURLWithPath: expand($0)) }
            let config = NSWorkspace.OpenConfiguration()
            if files.isEmpty {
                NSWorkspace.shared.openApplication(at: app, configuration: config)
            } else {
                NSWorkspace.shared.open(files, withApplicationAt: app, configuration: config)
            }
            return nil
        }

        // A command-line program on PATH: run it in a new Terminal window.
        if commandExists(first) {
            return openTerminal(cd: nil, command: text)
        }

        return "Can't find '\(text)'. Make sure you typed the name correctly, and then try again."
    }

    // MARK: Resolving

    static func findApp(_ name: String) -> URL? {
        let wanted = name.lowercased().replacingOccurrences(of: ".app", with: "")
        if wanted == "finder" { return URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app") }
        let dirs = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
                    NSHomeDirectory() + "/Applications", "/System/Library/CoreServices/Applications"]
        var prefixMatch: URL?
        for dir in dirs {
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for item in items where item.hasSuffix(".app") {
                let base = String(item.dropLast(4)).lowercased()
                if base == wanted { return URL(fileURLWithPath: dir).appendingPathComponent(item) }
                if prefixMatch == nil, wanted.count >= 3, base.hasPrefix(wanted) {
                    prefixMatch = URL(fileURLWithPath: dir).appendingPathComponent(item)
                }
            }
        }
        return prefixMatch
    }

    static func webURL(_ text: String) -> URL? {
        let lower = text.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("ftp://") { return URL(string: text) }
        if lower.hasPrefix("www.") { return URL(string: "https://" + text) }
        return nil
    }

    static func commandExists(_ name: String) -> Bool {
        if name.contains("/") { return FileManager.default.isExecutableFile(atPath: expand(name)) }
        let path = "/opt/homebrew/bin:/opt/homebrew/sbin:\(NSHomeDirectory())/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        return path.split(separator: ":").contains { FileManager.default.isExecutableFile(atPath: "\($0)/\(name)") }
    }

    /// ~ and $VARS expanded; Windows-style backslashes become slashes.
    static func expand(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: "\\", with: "/")
        // Longest names first, so $HOME doesn't replace the start of $HOMEBREW_PREFIX.
        for (key, value) in ProcessInfo.processInfo.environment.sorted(by: { $0.key.count > $1.key.count }) {
            s = s.replacingOccurrences(of: "$\(key)", with: value).replacingOccurrences(of: "%\(key)%", with: value)
        }
        return (s as NSString).expandingTildeInPath
    }

    static func isDirectory(_ path: String) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &dir) && dir.boolValue
    }

    /// Splits on spaces, keeping "quoted parts" together.
    static func split(_ text: String) -> [String] {
        var words: [String] = [], current = "", quoted = false
        for ch in text {
            if ch == "\"" { quoted.toggle(); continue }
            if ch == " " && !quoted {
                if !current.isEmpty { words.append(current); current = "" }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    // MARK: Terminal

    /// Opens a new Terminal window (needs one-time Automation permission for Terminal).
    static func openTerminal(cd folder: String?, command: String?) -> String? {
        var script = ""
        if let folder { script = "cd " + shellQuote(folder) }
        if let command { script = script.isEmpty ? command : script + " && " + command }
        let source = """
        tell application "Terminal"
            do script "\(script.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))"
            activate
        end tell
        """
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            NSLog("WinSwitch: Terminal script failed: \(error)")
            return "Could not open Terminal. Allow WinSwitch to control Terminal in System Settings > Privacy & Security > Automation."
        }
        return nil
    }

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
