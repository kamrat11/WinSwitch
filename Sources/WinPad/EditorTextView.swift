import AppKit

/// The plain text view: Cmd/Ctrl+scroll zooms, Esc closes the find bar, dropped files open in tabs, and the font
/// panel changes the WinPad font everywhere instead of the text's attributes.
@MainActor
final class EditorTextView: NSTextView {
    var onZoom: ((Int) -> Void)?
    var onEscape: (() -> Bool)?
    var onOpenFiles: (([URL]) -> Void)?
    private var scrollAccumulator: CGFloat = 0

    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) else {
            super.scrollWheel(with: event)
            return
        }
        if event.hasPreciseScrollingDeltas {
            scrollAccumulator += event.scrollingDeltaY
            guard abs(scrollAccumulator) >= 20 else { return }
            onZoom?(scrollAccumulator > 0 ? 1 : -1)
            scrollAccumulator = 0
        } else if event.scrollingDeltaY != 0 {
            onZoom?(event.scrollingDeltaY > 0 ? 1 : -1)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        if onEscape?() != true { super.cancelOperation(sender) }
    }

    override func changeFont(_ sender: Any?) {
        Preferences.font = NSFontManager.shared.convert(Preferences.font)
    }

    // MARK: Dropping files

    private func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(sender).isEmpty ? super.draggingEntered(sender) : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(sender).isEmpty ? super.draggingUpdated(sender) : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(sender)
        guard !urls.isEmpty else { return super.performDragOperation(sender) }
        DispatchQueue.main.async { self.onOpenFiles?(urls) }
        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        if let sender, !fileURLs(sender).isEmpty { return }
        super.concludeDragOperation(sender)
    }
}
