import AppKit
import ApplicationServices

// Private APIs, the same ones AltTab and DockDoor rely on.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ wid: UnsafeMutablePointer<CGWindowID>) -> AXError

@_silgen_name("_SLPSSetFrontProcessWithOptions")
private func _SLPSSetFrontProcessWithOptions(_ psn: UnsafeMutablePointer<ProcessSerialNumber>, _ wid: CGWindowID, _ mode: UInt32) -> CGError

@_silgen_name("SLPSPostEventRecordTo")
private func SLPSPostEventRecordTo(_ psn: UnsafeMutablePointer<ProcessSerialNumber>, _ bytes: UnsafeMutablePointer<UInt8>) -> CGError

@_silgen_name("GetProcessForPID")
private func GetProcessForPID(_ pid: pid_t, _ psn: UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> Int32

@_silgen_name("CGSCopySpacesForWindows")
private func CGSCopySpacesForWindows(_ cid: Int32, _ mask: Int32, _ wids: CFArray) -> CFArray?

struct WindowInfo: Equatable {
    let id: CGWindowID
    let pid: pid_t
    let title: String
    let bounds: CGRect
    let isMinimized: Bool
    let isOnScreen: Bool
    let app: NSRunningApplication

    var appName: String { app.localizedName ?? "" }
    var displayTitle: String { title.isEmpty ? appName : title }

    static func == (a: WindowInfo, b: WindowInfo) -> Bool { a.id == b.id }
}

enum Windows {
    /// Normal app windows, front-most first: visible windows on this Space, then other Spaces, then minimized.
    /// `includeMinimized: false` skips the Accessibility sweep of every app (slow with a hung app).
    static func list(pids: Set<pid_t>? = nil, includeMinimized: Bool = true) -> [WindowInfo] {
        // The running-apps list can briefly hold the same pid twice (an app quitting while another starts), so keep the newest.
        let hidden = Settings.hiddenBundleIds
        let apps = Dictionary(NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !hidden.contains($0.bundleIdentifier ?? "") }
            .map { ($0.processIdentifier, $0) }, uniquingKeysWith: { _, newest in newest })

        guard let raw = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }

        var onScreen: [WindowInfo] = []
        var offScreen: [WindowInfo] = []
        var seen = Set<CGWindowID>()

        for entry in raw {
            guard let id = entry[kCGWindowNumber as String] as? CGWindowID,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                  let app = apps[pid],
                  pids?.contains(pid) ?? true,
                  (entry[kCGWindowLayer as String] as? Int) == 0,
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width >= 100, bounds.height >= 60 else { continue }
            let alpha = entry[kCGWindowAlpha as String] as? Double ?? 1
            let visible = entry[kCGWindowIsOnscreen as String] as? Bool ?? false
            let title = entry[kCGWindowName as String] as? String ?? ""
            guard alpha > 0 else { continue }
            let info = WindowInfo(id: id, pid: pid, title: title, bounds: bounds, isMinimized: false, isOnScreen: visible, app: app)
            if visible {
                onScreen.append(info)
                seen.insert(id)
            } else if !title.isEmpty && !app.isHidden && isOnASpace(id) {
                // Off-screen windows include other Spaces and lots of helper windows; a title weeds most of those out.
                // The rest are on no Space at all: the background tabs of a tabbed window (Notepad, Terminal,
                // Finder), which have the window's title but cannot be switched to.
                offScreen.append(info)
            }
        }

        // Minimized windows come from Accessibility, which knows the minimized state.
        var minimized: [WindowInfo] = []
        var minimizedIds = Set<CGWindowID>()
        for app in apps.values where includeMinimized && pids?.contains(app.processIdentifier) ?? true {
            for element in axWindows(pid: app.processIdentifier) where axBool(element, kAXMinimizedAttribute) {
                guard let id = windowId(element), !seen.contains(id) else { continue }
                minimizedIds.insert(id)
                let title = axString(element, kAXTitleAttribute) ?? ""
                minimized.append(WindowInfo(id: id, pid: app.processIdentifier, title: title, bounds: .zero,
                                            isMinimized: true, isOnScreen: false, app: app))
            }
        }
        offScreen.removeAll { minimizedIds.contains($0.id) }

        return onScreen + offScreen + minimized
    }

    /// False for a window that is not shown on any Space (mask 7 = all Spaces), such as a background tab.
    private static func isOnASpace(_ id: CGWindowID) -> Bool {
        guard let spaces = CGSCopySpacesForWindows(CGSMainConnectionID(), 7, [id] as CFArray) as? [Any] else { return true }
        return !spaces.isEmpty
    }

    // MARK: Focus and close

    static func focus(_ window: WindowInfo) {
        let element = axElement(for: window)
        // The live state, not only the listed one: the window may have been minimized since it was listed.
        if let element, window.isMinimized || axBool(element, kAXMinimizedAttribute) {
            AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }

        var psn = ProcessSerialNumber()
        if GetProcessForPID(window.pid, &psn) == noErr {
            _ = _SLPSSetFrontProcessWithOptions(&psn, window.id, 0x200) // 0x200 = user generated
            makeKeyWindow(&psn, window.id)
        } else {
            window.app.activate()
        }
        if let element {
            AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        } else {
            raiseWithoutAccessibility(window)
        }
    }

    /// For when the app gives no accessibility element for the window (seen system-wide after a WindowServer
    /// crash: the window server then ignores the window id above too). The app is asked by Apple event to bring
    /// the window to its own front, then the whole app is activated, which still works.
    private static func raiseWithoutAccessibility(_ window: WindowInfo) {
        if let bundleId = window.app.bundleIdentifier {
            let name = window.title.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            let b = window.bounds
            let bounds = "{\(Int(b.minX)), \(Int(b.minY)), \(Int(b.maxX)), \(Int(b.maxY))}"
            // Terminal's window id is the CGWindowID. Elsewhere the window is found by its title; when several
            // share it, the one with the same frame and the same minimized state wins. A minimized window is restored first ("miniaturized"
            // in Cocoa apps, "minimized" in Chrome). All of it fails quietly in an app that is not scriptable.
            let find = bundleId == "com.apple.Terminal" ? "set target to \(window.id)" : """
            set target to missing value
                    set best to -1
                    repeat with w in windows
                        if name of w is "\(name)" then
                            set score to 0
                            if bounds of w is \(bounds) then set score to score + 2
                            set m to false
                            try
                                set m to miniaturized of w
                            end try
                            try
                                set m to minimized of w
                            end try
                            if m is \(window.isOnScreen ? "false" : "true") then set score to score + 1
                            if score > best then
                                set best to score
                                set target to id of w
                            end if
                        end if
                    end repeat
            """
            let source = """
            with timeout of 2 seconds
                tell application id "\(bundleId)"
                    \(find)
                    try
                        set miniaturized of window id target to false
                    end try
                    try
                        set minimized of window id target to false
                    end try
                    set index of window id target to 1
                end tell
            end timeout
            """
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
        }
        window.app.activate()
    }

    /// Brings one of WinSwitch's own windows to the front with keyboard focus. NSApp.activate() is only a request
    /// since macOS 14 and is often refused for a menu bar app, so this uses the same calls as focusing other windows.
    @MainActor
    static func focusOwn(_ window: NSWindow) {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        var psn = ProcessSerialNumber()
        guard GetProcessForPID(getpid(), &psn) == noErr else { return }
        let wid = CGWindowID(window.windowNumber)
        _ = _SLPSSetFrontProcessWithOptions(&psn, wid, 0x200)
        makeKeyWindow(&psn, wid)
    }

    /// The window that has keyboard focus in the front app.
    static func focusedWindowId() -> CGWindowID? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return windowId(value as! AXUIElement)
    }

    static func close(_ window: WindowInfo) {
        guard let element = axElement(for: window) else { return }
        var button: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXCloseButtonAttribute as CFString, &button) == .success, let button {
            AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
        }
    }

    static func setMinimized(_ window: WindowInfo, _ minimized: Bool) {
        guard let element = axElement(for: window) else { return }
        AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, minimized ? kCFBooleanTrue : kCFBooleanFalse)
    }

    /// Presses the window's own green button: full screen in most apps, zoom in the rest.
    static func zoom(_ window: WindowInfo) {
        guard let element = axElement(for: window) else { return }
        var button: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXZoomButtonAttribute as CFString, &button) == .success, let button {
            AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
        }
    }

    /// Whether the app still has the window (a closed one is gone; one asking to save changes is not).
    static func exists(_ window: WindowInfo) -> Bool { axElement(for: window) != nil }

    /// Makes `wid` the key window of its process with a synthetic mouse-down record (CGSEvent.h layout).
    /// The buffer is 0x100 although the record is 0xf8: the window server reads past the record on recent macOS.
    /// Only the down is posted and the point is far outside the window, so no control can be clicked.
    private static func makeKeyWindow(_ psn: inout ProcessSerialNumber, _ wid: CGWindowID) {
        var bytes = [UInt8](repeating: 0, count: 0x100)
        bytes[0x04] = 0xf8                       // record length
        bytes[0x08] = 0x01                       // left mouse down
        bytes[0x3a] = 0x10
        var point = CGPoint(x: 300_000, y: 300_000)
        var id = wid
        withUnsafeBytes(of: &point) { raw in for (i, b) in raw.enumerated() { bytes[0x20 + i] = b } }
        withUnsafeBytes(of: &id) { raw in for (i, b) in raw.enumerated() { bytes[0x3c + i] = b } }
        _ = SLPSPostEventRecordTo(&psn, &bytes)
    }

    // MARK: Accessibility helpers

    static func axElement(for window: WindowInfo) -> AXUIElement? {
        axWindows(pid: window.pid).first { windowId($0) == window.id }
    }

    static func axWindows(pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25) // never let a hung app freeze the switcher
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    static func windowId(_ element: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(element, &id) == .success && id != 0 ? id : nil
    }

    static func axString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    static func axBool(_ element: AXUIElement, _ attribute: String) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return false }
        return (value as? Bool) ?? false
    }
}
