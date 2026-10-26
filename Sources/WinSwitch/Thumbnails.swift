import AppKit
import ScreenCaptureKit

/// Window thumbnails through ScreenCaptureKit (needs Screen Recording permission).
/// Cached per window so the switcher can open instantly with the last image and refresh it.
@MainActor
final class Thumbnails {
    static let shared = Thumbnails()

    private var cache: [CGWindowID: NSImage] = [:]
    private var content: SCShareableContent?
    private var contentDate = Date.distantPast

    func cached(_ id: CGWindowID) -> NSImage? { cache[id] }

    /// Captures the windows (at most 4 at a time; bursts can wedge the capture daemon) and reports each image.
    func refresh(_ windows: [WindowInfo], maxPixelSize: CGFloat, onImage: @escaping (CGWindowID, NSImage) -> Void) {
        guard Permissions.screenRecordingGranted else { return }
        let targets = windows.filter { !$0.isMinimized }
        Task {
            guard let content = await shareableContent() else { return }
            let scWindows = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { a, _ in a })
            var queue = targets.compactMap { w in scWindows[w.id].map { (w, $0) } }[...]
            await withTaskGroup(of: (CGWindowID, NSImage?).self) { group in
                func addNext() {
                    guard let (window, scWindow) = queue.popFirst() else { return }
                    group.addTask { (window.id, await Self.capture(scWindow, maxPixelSize: maxPixelSize)) }
                }
                for _ in 0..<4 { addNext() }
                for await (id, image) in group {
                    if let image {
                        cache[id] = image
                        onImage(id, image)
                    }
                    addNext()
                }
            }
        }
    }

    private func shareableContent() async -> SCShareableContent? {
        if let content, Date().timeIntervalSince(contentDate) < 1 { return content }
        do {
            let fresh = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            content = fresh
            contentDate = Date()
            return fresh
        } catch {
            NSLog("WinSwitch: SCShareableContent failed: \(error)")
            return nil
        }
    }

    private nonisolated static func capture(_ window: SCWindow, maxPixelSize: CGFloat) async -> NSImage? {
        let frame = window.frame
        guard frame.width > 1, frame.height > 1 else { return nil }
        let scale = min(1, maxPixelSize / max(frame.width, frame.height))
        let config = SCStreamConfiguration()
        config.width = Int(frame.width * scale * 2)   // 2x for Retina
        config.height = Int(frame.height * scale * 2)
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        let filter = SCContentFilter(desktopIndependentWindow: window)
        do {
            let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            return NSImage(cgImage: cgImage, size: NSSize(width: frame.width * scale, height: frame.height * scale))
        } catch {
            return nil
        }
    }

    /// Drops images of windows that no longer exist.
    func prune(keeping ids: Set<CGWindowID>) {
        cache = cache.filter { ids.contains($0.key) }
    }
}
