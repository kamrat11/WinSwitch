import AppKit
import ApplicationServices

/// Shows an app's windows as a row of thumbnails while the mouse rests on its Dock icon.
/// The Dock marks the hovered icon as its list's selected child, so we watch that through Accessibility.
@MainActor
final class DockPreviews {
    private var observer: AXObserver?
    private var dockPid: pid_t = 0
    private var dockList: AXUIElement?
    private var healthTimer: Timer?

    private let panel = FloatingPanel()
    private var tiles: [WindowTile] = []
    private var currentItem: AXUIElement?
    /// The hovered icon's frame, so clicking the icon keeps its preview open (like the Windows taskbar).
    private var currentIconFrame: CGRect?
    private var showWork: DispatchWorkItem?
    private var hideTimer: Timer?
    private var clickMonitor: Any?

    func start() {
        subscribe()
        // Re-subscribe if the Dock restarts (killall Dock, or a macOS update).
        healthTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier ?? 0
                // Also retry when the last attempt failed (a Dock that just restarted has no icon list yet).
                if pid != self.dockPid || self.observer == nil { self.subscribe() }
            }
        }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.panel.isVisible else { return }
                if !self.mouseOnPreviewOrIcon(margin: 0) { self.hide() }
            }
        }
    }

    private func subscribe() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        dockList = nil
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return }
        dockPid = dock.processIdentifier

        let dockElement = AXUIElementCreateApplication(dockPid)
        guard let list = Self.children(dockElement).first(where: { Self.string($0, kAXRoleAttribute) == kAXListRole }) else { return }

        var newObserver: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let me = Unmanaged<DockPreviews>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { me.selectionChanged() }
        }
        guard AXObserverCreate(dockPid, callback, &newObserver) == .success, let newObserver else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard AXObserverAddNotification(newObserver, list, kAXSelectedChildrenChangedNotification as CFString, refcon) == .success else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(newObserver), .commonModes)
        observer = newObserver
        dockList = list
    }

    // MARK: Hover

    private func hoveredItem() -> AXUIElement? {
        guard let dockList else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(dockList, kAXSelectedChildrenAttribute as CFString, &value) == .success else { return nil }
        return (value as? [AXUIElement])?.first
    }

    private func selectionChanged() {
        showWork?.cancel()
        guard Settings.dockActivation != .off, let item = hoveredItem() else { return }
        if let currentItem, CFEqual(currentItem, item), panel.isVisible { return }

        let work = DispatchWorkItem { [weak self] in self?.show(item) }
        showWork = work
        // The first preview waits a little. With one open, another icon takes over at once, except on the way from
        // the icon to its previews: there the mouse has to rest on the other icon, so brushing past it on the way up
        // keeps the previews (like the Windows taskbar).
        let delay = panel.isVisible ? (mouseOnTheWayToPreview() ? 0.35 : 0.05) : Settings.dockHoverDelay
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func show(_ item: AXUIElement) {
        guard let hovered = hoveredItem(), CFEqual(hovered, item) else { return }
        if Settings.dockActivation == .hoverWithOption && !NSEvent.modifierFlags.contains(.option) { return }
        guard Self.string(item, kAXSubroleAttribute) == "AXApplicationDockItem",
              let pids = Self.pids(for: item), !pids.isEmpty else { hide(); return }

        let windows = Windows.list(pids: pids)
        guard !windows.isEmpty else { hide(); return }

        currentItem = item
        tiles = windows.map { window in
            let tile = WindowTile(window: window, image: Thumbnails.shared.cached(window.id))
            tile.onHover = { [weak self] in self?.highlight(window.id) }
            tile.onClick = { [weak self] in
                self?.hide()
                Windows.focus(window)
            }
            tile.showsControls = true
            tile.onClose = { [weak self] in self?.close(window) }
            tile.onToggleMinimize = { [weak self, weak tile] in
                if let tile { self?.toggleMinimized(tile) }
            }
            tile.onZoom = { [weak self, weak tile] in
                if let tile { self?.zoom(tile) }
            }
            return tile
        }

        guard let iconFrame = Self.frame(of: item), let visible = Self.visibleFrame(around: iconFrame) else { return }
        currentIconFrame = iconFrame
        panel.show(tiles: tiles, maxWidth: visible.width * 0.9)
        panel.setFrameOrigin(Self.origin(for: panel.frame.size, near: iconFrame, in: visible))
        panel.orderFrontRegardless()
        tiles.forEach { $0.refreshHover() }
        startHideTimer()

        Thumbnails.shared.refresh(windows, maxPixelSize: WindowTile.thumbSize.width) { [weak self] id, image in
            self?.tiles.first { $0.info.id == id }?.setImage(image)
        }
    }

    private func highlight(_ id: CGWindowID) {
        for tile in tiles { tile.isSelected = tile.info.id == id }
    }

    // MARK: Close, minimize and restore

    /// The green button: restores a minimized window; any other window comes to the front and gets its own green
    /// button pressed (full screen in most apps).
    private func zoom(_ tile: WindowTile) {
        if tile.isMinimized { toggleMinimized(tile); return }
        let window = tile.info
        hide()
        Windows.focus(window)
        Windows.zoom(window)
    }

    /// The yellow button: minimizes the window, or restores a minimized one and brings it to the front.
    /// The previews stay open either way.
    private func toggleMinimized(_ tile: WindowTile) {
        let window = tile.info
        if tile.isMinimized {
            Windows.focus(window)
            tile.isMinimized = false
            // A fresh thumbnail once the window is back out of the Dock.
            let restored = WindowInfo(id: window.id, pid: window.pid, title: window.title, bounds: window.bounds,
                                      isMinimized: false, isOnScreen: true, app: window.app)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self, self.panel.isVisible else { return }
                Thumbnails.shared.refresh([restored], maxPixelSize: WindowTile.thumbSize.width) { [weak self] id, image in
                    self?.tiles.first { $0.info.id == id && !$0.isMinimized }?.setImage(image)
                }
            }
        } else {
            Windows.setMinimized(window, true)
            tile.isMinimized = true
        }
    }

    /// The red button. The tile goes once the window is really gone; a window that stays (it is asking to save
    /// changes) is brought to the front instead so the question can be answered.
    private func close(_ window: WindowInfo) {
        guard let tile = tiles.first(where: { $0.info.id == window.id }), tile.alphaValue == 1 else { return }
        tile.alphaValue = 0.4
        Windows.close(window)
        waitForClose(window, attempt: 0)
    }

    private func waitForClose(_ window: WindowInfo, attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, self.panel.isVisible, let index = self.tiles.firstIndex(where: { $0.info.id == window.id }) else { return }
            if !Windows.exists(window) {
                self.removeTile(at: index)
            } else if attempt < 12 {
                self.waitForClose(window, attempt: attempt + 1)
            } else {
                self.hide()
                Windows.focus(window)
            }
        }
    }

    /// Drops a tile and closes the gap. The tile that takes its place lands exactly where the closed one was, so
    /// the mouse is already on the next close button and several windows can be closed without moving it.
    private func removeTile(at index: Int) {
        let old = tiles[index]
        let oldFrame = panel.convertToScreen(old.convert(old.bounds, to: nil))
        tiles.remove(at: index)
        guard !tiles.isEmpty, let currentIconFrame, let visible = Self.visibleFrame(around: currentIconFrame) else { hide(); return }

        panel.show(tiles: tiles, maxWidth: visible.width * 0.9)
        let next = tiles[min(index, tiles.count - 1)]
        let newFrame = panel.convertToScreen(next.convert(next.bounds, to: nil))
        let size = panel.frame.size
        var origin = panel.frame.origin
        origin.x += oldFrame.minX - newFrame.minX
        origin.y += oldFrame.minY - newFrame.minY
        origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
        origin.y = min(max(origin.y, visible.minY + 4), visible.maxY - size.height - 4)
        panel.setFrameOrigin(origin)
        tiles.forEach { $0.refreshHover() }
    }

    /// Keeps the preview while the mouse is on it or still on the same Dock icon.
    private func startHideTimer() {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.mouseOnPreviewOrIcon(margin: 6) || self.mouseOnTheWayToPreview() { return }
                // On another icon the switch to its previews is already scheduled; hiding first would make it flicker.
                if self.hoveredItem() != nil { return }
                self.hide()
            }
        }
    }

    /// True while the mouse is on the preview panel or on the Dock icon it belongs to. Clicking the icon makes
    /// the Dock drop its hover selection, so the icon's own frame is checked too.
    private func mouseOnPreviewOrIcon(margin: CGFloat) -> Bool {
        let mouse = NSEvent.mouseLocation
        if NSMouseInRect(mouse, panel.frame.insetBy(dx: -margin, dy: -2 * margin), false) { return true }
        if let currentIconFrame, NSMouseInRect(mouse, currentIconFrame, false) { return true }
        return false
    }

    /// True while the mouse is between the hovered icon and its previews: the box spanning both, so a diagonal
    /// move to a preview that isn't straight above the icon still counts.
    private func mouseOnTheWayToPreview() -> Bool {
        guard panel.isVisible, let currentIconFrame else { return false }
        return NSMouseInRect(NSEvent.mouseLocation, currentIconFrame.union(panel.frame), false)
    }

    func hide() {
        showWork?.cancel()
        hideTimer?.invalidate()
        hideTimer = nil
        currentItem = nil
        currentIconFrame = nil
        panel.orderOut(nil)
    }

    // MARK: Geometry

    /// The usable area of the screen the Dock icon is on.
    private static func visibleFrame(around iconFrame: CGRect) -> CGRect? {
        let center = NSPoint(x: iconFrame.midX, y: iconFrame.midY)
        return (NSScreen.screens.first { NSPointInRect(center, $0.frame) } ?? NSScreen.main)?.visibleFrame
    }

    /// Places the panel just above (or beside) the Dock icon, kept inside the screen.
    private static func origin(for size: NSSize, near icon: CGRect, in visible: CGRect) -> NSPoint {
        let orientation = UserDefaults(suiteName: "com.apple.dock")?.string(forKey: "orientation") ?? "bottom"
        var origin: NSPoint
        switch orientation {
        case "left":
            origin = NSPoint(x: icon.maxX + 6, y: icon.midY - size.height / 2)
        case "right":
            origin = NSPoint(x: icon.minX - size.width - 6, y: icon.midY - size.height / 2)
        default:
            origin = NSPoint(x: icon.midX - size.width / 2, y: icon.maxY + 6)
        }
        origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
        origin.y = min(max(origin.y, visible.minY + 4), visible.maxY - size.height - 4)
        return origin
    }

    /// The icon's frame in Cocoa coordinates (AX uses a top-left origin on the primary screen).
    private static func frame(of item: AXUIElement) -> CGRect? {
        var posValue: CFTypeRef?, sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(item, kAXPositionAttribute as CFString, &posValue) == .success,
              AXUIElementCopyAttributeValue(item, kAXSizeAttribute as CFString, &sizeValue) == .success else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(posValue as! AXValue, .cgPoint, &point)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: point.x, y: primaryHeight - point.y - size.height, width: size.width, height: size.height)
    }

    // MARK: AX helpers

    /// Running processes of the app behind a Dock item (by its bundle URL, falling back to its title).
    private static func pids(for item: AXUIElement) -> Set<pid_t>? {
        var urlValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(item, kAXURLAttribute as CFString, &urlValue) == .success,
           let url = urlValue as? URL ?? (urlValue as? NSURL) as URL?,
           let bundleId = Bundle(url: url)?.bundleIdentifier {
            return Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).map(\.processIdentifier))
        }
        guard let title = string(item, kAXTitleAttribute) else { return nil }
        return Set(NSWorkspace.shared.runningApplications.filter { $0.localizedName == title }.map(\.processIdentifier))
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
