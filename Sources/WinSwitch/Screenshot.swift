import AppKit
import ScreenCaptureKit

/// PrtSc and Alt+PrtSc, captured in-process with ScreenCaptureKit (the Screen Recording permission WinSwitch already has
/// for thumbnails). Running /usr/sbin/screencapture from WinSwitch could get blank web pages, and the macOS screenshot
/// shortcut copies the main display rather than the one you're working on.
@MainActor
enum Screenshot {
    /// PrtSc: the screen under the mouse, to the clipboard.
    static func screenUnderMouse() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main,
              let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return }
        let scale = screen.backingScaleFactor
        let size = screen.frame.size
        Task {
            guard let content = await shareableContent(),
                  let display = content.displays.first(where: { $0.displayID == displayID }) else { return fallback(["-c", "-m"]) }
            let config = SCStreamConfiguration()
            config.width = Int(size.width * scale)
            config.height = Int(size.height * scale)
            config.showsCursor = false
            let filter = SCContentFilter(display: display, excludingWindows: [])
            await capture(filter, config, pointSize: size, label: "Screen copied")
        }
    }

    /// Alt+PrtSc: the focused window of the app you're in, to the clipboard.
    static func frontWindow() {
        let activePid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let onScreen = Windows.list(includeMinimized: false).filter(\.isOnScreen)
        let id = Windows.focusedWindowId() ?? (onScreen.first { $0.pid == activePid } ?? onScreen.first)?.id
        guard let id else { return }
        Task {
            guard let content = await shareableContent(), let window = content.windows.first(where: { $0.windowID == id }) else {
                return fallback(["-c", "-o", "-l", String(id)])
            }
            let frame = window.frame
            let center = NSPoint(x: frame.midX, y: (NSScreen.screens.first?.frame.height ?? 0) - frame.midY)
            let scale = NSScreen.screens.first { NSMouseInRect(center, $0.frame, false) }?.backingScaleFactor ?? 2
            let config = SCStreamConfiguration()
            config.width = Int(frame.width * scale)
            config.height = Int(frame.height * scale)
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = true
            await capture(SCContentFilter(desktopIndependentWindow: window), config, pointSize: frame.size, label: "Window copied")
        }
    }

    private static func shareableContent() async -> SCShareableContent? {
        guard Permissions.screenRecordingGranted else { return nil }
        return try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }

    private static func capture(_ filter: SCContentFilter, _ config: SCStreamConfiguration, pointSize: CGSize, label: String) async {
        do {
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            copy(image, pointSize: pointSize)
            playSound()
            HUD.shared.show(label, symbol: "camera.viewfinder")
        } catch {
            NSLog("WinSwitch: screenshot failed: \(error)")
            HUD.shared.show("Screenshot failed", symbol: "exclamationmark.triangle")
        }
    }

    /// PNG and TIFF, so both modern apps and older ones can paste it.
    private static func copy(_ image: CGImage, pointSize: CGSize) {
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = pointSize
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.declareTypes([.png, .tiff], owner: nil)
        if let png = rep.representation(using: .png, properties: [:]) { pb.setData(png, forType: .png) }
        if let tiff = rep.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
    }

    private static func playSound() {
        let path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif"
        NSSound(contentsOfFile: path, byReference: true)?.play()
    }

    /// Without Screen Recording permission: the system tool, and a hint about the permission.
    private static func fallback(_ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = arguments
        try? process.run()
        if !Permissions.screenRecordingGranted { HUD.shared.show("Allow Screen Recording for WinSwitch", symbol: "exclamationmark.triangle") }
    }
}
