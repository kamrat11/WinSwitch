import AppKit
import ApplicationServices

/// Windows in the order they were last focused, most recent first, like the Windows Alt+Tab order.
/// Fed by app activations and each app's focused-window changes (Accessibility notifications).
@MainActor
final class WindowHistory {
    static let shared = WindowHistory()

    private var order: [CGWindowID] = []
    private var observers: [pid_t: AXObserver] = [:]

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated {
                self.watch(app)
                self.recordFocusedWindow(of: app.processIdentifier)
            }
        }
        center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self.watch(app) }
        }
        center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self.unwatch(app.processIdentifier) }
        }
        for app in NSWorkspace.shared.runningApplications { watch(app) }
        if let front = NSWorkspace.shared.frontmostApplication { recordFocusedWindow(of: front.processIdentifier) }
    }

    /// Sorts windows most recently focused first; windows not focused since WinSwitch started keep their order after those.
    func sorted(_ windows: [WindowInfo]) -> [WindowInfo] {
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return windows.enumerated().sorted { a, b in
            switch (rank[a.element.id], rank[b.element.id]) {
            case let (ra?, rb?): return ra < rb
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a.offset < b.offset
            }
        }.map(\.element)
    }

    func record(_ id: CGWindowID) {
        order.removeAll { $0 == id }
        order.insert(id, at: 0)
        if order.count > 500 { order.removeLast(order.count - 500) }
    }

    private func recordFocusedWindow(of pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID(),
              let id = Windows.windowId(value as! AXUIElement) else { return }
        record(id)
    }

    private func watch(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard app.activationPolicy == .regular, observers[pid] == nil, pid != getpid() else { return }
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, element, _, refcon in
            let history = Unmanaged<WindowHistory>.fromOpaque(refcon!).takeUnretainedValue()
            MainActor.assumeIsolated {
                if let id = Windows.windowId(element) { history.record(id) }
            }
        }
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }
        let element = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification] {
            AXObserverAddNotification(observer, element, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        observers[pid] = observer
    }

    private func unwatch(_ pid: pid_t) {
        guard let observer = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        // Every window that still exists (hidden apps and untitled windows included), not just the switcher's list.
        let raw = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        let alive = Set(raw.compactMap { $0[kCGWindowNumber as String] as? CGWindowID })
        order.removeAll { !alive.contains($0) }
    }
}
