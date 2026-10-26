import AppKit

/// What the Task Manager can do to a process: end it, suspend it, change its priority, find its file.
@MainActor
enum ProcessActions {
    private typealias UnresponsiveFn = @convention(c) (Int32, UnsafePointer<ProcessSerialNumber>) -> Bool
    private typealias ConnectionFn = @convention(c) () -> Int32
    private static let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
    private static let unresponsiveFn: UnresponsiveFn? = dlsym(defaultHandle, "CGSEventIsAppUnresponsive")
        .map { unsafeBitCast($0, to: UnresponsiveFn.self) }
    private static let connectionFn: ConnectionFn? = (dlsym(defaultHandle, "SLSMainConnectionID") ?? dlsym(defaultHandle, "CGSMainConnectionID"))
        .map { unsafeBitCast($0, to: ConnectionFn.self) }

    /// "Not responding": the app has stopped handling events (the spinning wait cursor).
    static func isNotResponding(_ pid: pid_t) -> Bool {
        guard let unresponsiveFn, let connectionFn else { return false }
        var psn = ProcessSerialNumber()
        guard GetProcessForPID(pid, &psn) == noErr else { return false }
        return unresponsiveFn(connectionFn(), &psn)
    }

    // MARK: Ending

    /// End task on an app: ask it to quit (it may ask to save documents); force it if it isn't responding.
    static func endApp(_ app: NSRunningApplication) {
        if isNotResponding(app.processIdentifier) || !app.terminate() {
            if !app.forceTerminate() { endProcess(app.processIdentifier, name: app.localizedName ?? "", force: true) }
        }
    }

    /// End task on a process: SIGTERM, then SIGKILL if it is still there two seconds later.
    static func endProcess(_ pid: pid_t, name: String, force: Bool = false) {
        guard pid > 1 else { return }
        if kill(pid, force ? SIGKILL : SIGTERM) != 0 {
            if errno == EPERM { askToElevate("kill -\(force ? 9 : 15) \(pid)", what: "end \(name)") }
            return
        }
        guard !force else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        }
    }

    /// End process tree: the process and everything it started, children first.
    static func endTree(_ pid: pid_t, name: String, in processes: [ProcessSample]) {
        var children: [pid_t: [pid_t]] = [:]
        for p in processes { children[p.ppid, default: []].append(p.pid) }
        var order: [pid_t] = []
        func visit(_ p: pid_t) {
            for child in children[p] ?? [] where child != p { visit(child) }
            order.append(p)
        }
        visit(pid)
        var denied: [pid_t] = []
        for p in order where kill(p, SIGKILL) != 0 && errno == EPERM { denied.append(p) }
        if !denied.isEmpty {
            askToElevate("kill -9 " + denied.map(String.init).joined(separator: " "), what: "end the process tree of \(name)")
        }
    }

    static func setSuspended(_ pid: pid_t, name: String, _ suspend: Bool) {
        if kill(pid, suspend ? SIGSTOP : SIGCONT) != 0 && errno == EPERM {
            askToElevate("kill -\(suspend ? "STOP" : "CONT") \(pid)", what: "\(suspend ? "suspend" : "resume") \(name)")
        }
    }

    /// Windows priority classes mapped onto nice values. Raising the priority needs an administrator.
    static let priorities: [(title: String, nice: Int32)] = [
        ("Realtime", -20), ("High", -10), ("Above normal", -5), ("Normal", 0), ("Below normal", 5), ("Low", 10),
    ]

    static func priorityName(_ nice: Int32) -> String {
        priorities.min { abs($0.nice - nice) < abs($1.nice - nice) }?.title ?? "Normal"
    }

    static func setPriority(_ pid: pid_t, name: String, nice: Int32) {
        if setpriority(PRIO_PROCESS, id_t(pid), nice) != 0 && (errno == EPERM || errno == EACCES) {
            askToElevate("/usr/bin/renice \(nice) -p \(pid)", what: "change the priority of \(name)")
        }
    }

    // MARK: Files

    static func openFileLocation(_ path: String) {
        guard !path.isEmpty else { return }
        let url = URL(fileURLWithPath: bundlePath(of: path) ?? path)
        Explorer.openWindow(at: url.deletingLastPathComponent(), select: url)
    }

    static func searchOnline(_ name: String) {
        var components = URLComponents(string: "https://www.google.com/search")!
        components.queryItems = [URLQueryItem(name: "q", value: "\(name) macOS process")]
        if let url = components.url { NSWorkspace.shared.open(url) }
    }

    /// The outermost .app bundle a path is inside of, if any.
    nonisolated static func bundlePath(of path: String) -> String? {
        guard let range = path.range(of: ".app/") else { return path.hasSuffix(".app") ? path : nil }
        return String(path[..<range.lowerBound]) + ".app"
    }

    // MARK: Administrator

    /// Like "Access is denied" in Windows, but offers to retry with an administrator password.
    static func askToElevate(_ command: String, what: String) {
        let alert = NSAlert()
        alert.messageText = "Access is denied"
        alert.informativeText = "WinSwitch can't \(what) because it belongs to another user or to macOS. Try again as an administrator?"
        alert.addButton(withTitle: "Run as administrator")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        runAsAdministrator(command)
    }

    @discardableResult
    static func runAsAdministrator(_ command: String) -> Bool {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        var error: NSDictionary?
        NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")?.executeAndReturnError(&error)
        if let error, (error[NSAppleScript.errorNumber] as? Int) != -128 { // -128: the user cancelled
            let alert = NSAlert()
            alert.messageText = "The operation failed"
            alert.informativeText = error[NSAppleScript.errorMessage] as? String ?? "Unknown error"
            alert.runModal()
            return false
        }
        return error == nil
    }

    static func confirm(_ title: String, _ text: String, button: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

@_silgen_name("GetProcessForPID")
private func GetProcessForPID(_ pid: pid_t, _ psn: UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
