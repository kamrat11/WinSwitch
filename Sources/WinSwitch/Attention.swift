import AppKit
import ApplicationServices

/// Which apps and windows are asking for attention, for the marks on the Alt+Tab and Dock preview tiles.
///
/// macOS only says this per app: the badge on its Dock icon, read here once a second through Accessibility.
/// Terminal gets the window too. Its badge is the number of windows with an unread bell, and it tells nobody which
/// ones, so when the badge goes up the bell is pinned on the window whose tty wrote at that moment and then went
/// quiet (a program that rings is waiting; the busy ones keep writing). Looking at the window clears it, as in
/// Terminal. Bells that rang before WinSwitch started are not known.
@MainActor
final class Attention {
    static let shared = Attention()
    private static let terminal = "com.apple.Terminal"

    private var timer: Timer?
    private var badges: [String: String] = [:]
    private var bundleIds: [URL: String] = [:]
    private var alerting = Set<CGWindowID>()
    private var dockPid: pid_t = 0
    private var dockList: AXUIElement?
    private var lastPoll: Date?

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    /// The badge on the app's Dock icon ("3", or whatever the app put there).
    func badge(for app: NSRunningApplication) -> String? {
        app.bundleIdentifier.flatMap { badges[$0] }
    }

    /// True for a Terminal window whose bell rang and that has not been looked at since.
    func isAlerting(_ id: CGWindowID) -> Bool { alerting.contains(id) }

    private func poll() {
        guard let fresh = readBadges() else { return } // the Dock is restarting: keep what we know
        let now = Date()
        let before = Int(badges[Self.terminal] ?? "") ?? 0
        let after = Int(fresh[Self.terminal] ?? "") ?? 0
        badges = fresh

        let terminalInFront = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.terminal
        let focused = terminalInFront ? Windows.focusedWindowId() : nil
        if let focused { alerting.remove(focused) }
        if after == 0 { alerting.removeAll() }
        if after > before, let lastPoll {
            pinBells(after - before, from: lastPoll.addingTimeInterval(-0.3), to: now.addingTimeInterval(0.3), focused: focused)
        }
        lastPoll = now
    }

    /// Marks the `count` Terminal windows that rang between the two polls, once it is clear which went quiet.
    private func pinBells(_ count: Int, from: Date, to: Date, focused: CGWindowID?) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self else { return }
            let quiet = Self.ttyWriteTimes().filter { $0.value > from && $0.value <= to }
            guard !quiet.isEmpty else { return }
            let windows = Self.terminalWindowsByTTY()
            let ids = quiet.sorted { $0.value > $1.value }
                .compactMap { windows[$0.key] }
                .filter { $0 != focused && !self.alerting.contains($0) }
            for id in ids.prefix(count) { self.alerting.insert(id) }
        }
    }

    // MARK: Dock badges

    private func readBadges() -> [String: String]? {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
        if dock.processIdentifier != dockPid || dockList == nil {
            dockPid = dock.processIdentifier
            let element = AXUIElementCreateApplication(dockPid)
            AXUIElementSetMessagingTimeout(element, 0.25)
            dockList = Self.elements(element, kAXChildrenAttribute)?.first { Windows.axString($0, kAXRoleAttribute) == kAXListRole }
        }
        guard let dockList, let items = Self.elements(dockList, kAXChildrenAttribute) else {
            dockList = nil
            return nil
        }
        var result: [String: String] = [:]
        for item in items {
            guard let label = Windows.axString(item, "AXStatusLabel"), !label.isEmpty else { continue }
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(item, kAXURLAttribute as CFString, &value) == .success,
                  let url = value as? URL ?? (value as? NSURL) as URL? else { continue }
            let bundleId = bundleIds[url] ?? Bundle(url: url)?.bundleIdentifier
            bundleIds[url] = bundleId
            if let bundleId { result[bundleId] = label }
        }
        return result
    }

    private static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? [AXUIElement]
    }

    // MARK: Terminal

    /// When each terminal device was last written to (a tty's modification time is its last output).
    private static func ttyWriteTimes() -> [String: Date] {
        var result: [String: Date] = [:]
        for name in (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? [] where name.hasPrefix("ttys") {
            var info = stat()
            guard stat("/dev/" + name, &info) == 0 else { continue }
            result["/dev/" + name] = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9)
        }
        return result
    }

    /// Terminal's windows by the tty of each of their tabs. Terminal's scripting window id is the window number.
    private static func terminalWindowsByTTY() -> [String: CGWindowID] {
        let source = """
        set out to ""
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    set out to out & (id of w) & " " & (tty of t) & linefeed
                end repeat
            end repeat
        end tell
        return out
        """
        var error: NSDictionary?
        let output = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue ?? ""
        if let error { NSLog("WinSwitch: Terminal windows: \(error)") }
        var result: [String: CGWindowID] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ")
            if parts.count == 2, let id = CGWindowID(parts[0]) { result[String(parts[1])] = id }
        }
        return result
    }
}
