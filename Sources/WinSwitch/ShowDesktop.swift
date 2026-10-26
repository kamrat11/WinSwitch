import AppKit
import ApplicationServices

/// Win+D: the first press hides every app with a visible window, the second brings back the same apps and the
/// window that was in front. Using any app in between starts over, as on Windows.
@MainActor
enum ShowDesktop {
    private static var hiddenApps: [NSRunningApplication] = []
    private static var frontWindow: WindowInfo?

    static func toggle() {
        let stillHidden = hiddenApps.filter { !$0.isTerminated }
        if !stillHidden.isEmpty && stillHidden.allSatisfy(\.isHidden) {
            restore(stillHidden)
        } else {
            showDesktop()
        }
    }

    /// Brings back everything the last Win+D hid, even if some of those apps were used in between.
    static func restoreAll() {
        let apps = hiddenApps.filter { !$0.isTerminated }
        if !apps.isEmpty { restore(apps) }
    }

    private static func showDesktop() {
        let visible = Windows.list(includeMinimized: false).filter { $0.isOnScreen }
        frontWindow = WindowHistory.shared.sorted(visible).first
        var seen = Set<pid_t>()
        hiddenApps = visible.map(\.app).filter { !$0.isHidden && seen.insert($0.processIdentifier).inserted }
        // Hiding the front app makes macOS activate another one, which can undo a hide still in flight; so hide
        // the front app last and go over the list again until everything stayed hidden.
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        hiddenApps = hiddenApps.filter { $0.processIdentifier != front } + hiddenApps.filter { $0.processIdentifier == front }
        hideRemaining(attempt: 0)
    }

    private static func hideRemaining(attempt: Int) {
        let showing = hiddenApps.filter { !$0.isTerminated && !$0.isHidden }
        guard !showing.isEmpty, attempt < 5 else { return }
        for app in showing {
            // Some apps (Chrome, Reminders) ignore a hide request from another app; Accessibility hiding still works.
            if attempt == 0 {
                app.hide()
            } else {
                AXUIElementSetAttributeValue(AXUIElementCreateApplication(app.processIdentifier),
                                             kAXHiddenAttribute as CFString, kCFBooleanTrue)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { hideRemaining(attempt: attempt + 1) }
    }

    private static func restore(_ apps: [NSRunningApplication]) {
        for app in apps {
            app.unhide()
            AXUIElementSetAttributeValue(AXUIElementCreateApplication(app.processIdentifier),
                                         kAXHiddenAttribute as CFString, kCFBooleanFalse)
        }
        hiddenApps = []
        // Unhiding is asynchronous; focus the previous window once its app is back.
        if let window = frontWindow {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { Windows.focus(window) }
        }
        frontWindow = nil
    }
}
