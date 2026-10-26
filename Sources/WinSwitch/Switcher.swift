import AppKit

/// Windows-style Alt+Tab: one tile per window, release Alt to switch.
@MainActor
final class Switcher {
    private(set) var isShowing = false

    private let panel = FloatingPanel()
    private var windows: [WindowInfo] = []
    private var tiles: [WindowTile] = []
    private var selected = 0
    private var showWork: DispatchWorkItem?

    func open(reverse: Bool) {
        windows = WindowHistory.shared.sorted(Windows.list())
        // The window in use always comes first, so a quick Alt+Tab never "switches" to it.
        if let current = Windows.focusedWindowId(), let i = windows.firstIndex(where: { $0.id == current }), i > 0 {
            windows.insert(windows.remove(at: i), at: 0)
        }
        guard !windows.isEmpty else { return }
        isShowing = true
        // The first window is the one in front, so a quick Alt+Tab goes to the previous one.
        selected = reverse ? windows.count - 1 : min(1, windows.count - 1)

        tiles = windows.enumerated().map { index, window in
            let tile = WindowTile(window: window, image: Thumbnails.shared.cached(window.id))
            tile.onClick = { [weak self] in
                self?.select(index)
                self?.commit()
            }
            return tile
        }
        select(selected)

        // Like Windows, a quick Alt+Tab switches without flashing the switcher on screen.
        let work = DispatchWorkItem { [weak self] in self?.present() }
        showWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)

        let ids = windows.map(\.id)
        Thumbnails.shared.prune(keeping: Set(ids))
        Thumbnails.shared.refresh(windows, maxPixelSize: WindowTile.thumbSize.width) { [weak self] id, image in
            self?.tiles.first { $0.info.id == id }?.setImage(image)
        }
    }

    private func present() {
        guard isShowing else { return }
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        panel.show(tiles: tiles, maxWidth: frame.width * 0.9)
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2 + frame.height * 0.08))
        panel.orderFrontRegardless()
    }

    func step(_ delta: Int) {
        guard isShowing, !windows.isEmpty else { return }
        select((selected + delta + windows.count) % windows.count)
    }

    private func select(_ index: Int) {
        guard tiles.indices.contains(index) else { return }
        if tiles.indices.contains(selected) { tiles[selected].isSelected = false }
        selected = index
        tiles[index].isSelected = true
    }

    func commit() {
        guard isShowing else { return }
        let target = windows.indices.contains(selected) ? windows[selected] : nil
        dismiss()
        if let target {
            Windows.focus(target)
            WindowHistory.shared.record(target.id)
        }
    }

    func cancel() {
        dismiss()
    }

    /// Alt+W or Alt+F4 while the switcher is open closes the highlighted window.
    func closeSelected() {
        guard isShowing, windows.indices.contains(selected) else { return }
        Windows.close(windows[selected])
        tiles[selected].removeFromSuperview()
        windows.remove(at: selected)
        tiles.remove(at: selected)
        if windows.isEmpty { dismiss(); return }
        for (i, tile) in tiles.enumerated() {
            tile.onClick = { [weak self] in self?.select(i); self?.commit() }
        }
        selected = min(selected, windows.count - 1)
        tiles[selected].isSelected = true
        if panel.isVisible { present() }
    }

    private func dismiss() {
        isShowing = false
        showWork?.cancel()
        panel.orderOut(nil)
    }
}
