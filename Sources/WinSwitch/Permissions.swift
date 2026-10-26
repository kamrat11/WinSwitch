import AppKit
import ApplicationServices

enum Permissions {
    enum Pane {
        case accessibility, screenRecording, inputMonitoring, fullDiskAccess

        var url: URL {
            switch self {
            case .accessibility:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            case .screenRecording:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
            case .inputMonitoring:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
            case .fullDiskAccess:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
            }
        }
    }

    static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    static var screenRecordingGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system prompt (once) that adds WinSwitch to the Accessibility list.
    static func requestAccessibility() {
        guard !accessibilityGranted else { return }
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Adds WinSwitch to the Screen Recording list and prompts once.
    static func requestScreenRecording() {
        guard !screenRecordingGranted else { return }
        _ = CGRequestScreenCaptureAccess()
    }

    /// The system TCC database is readable only with Full Disk Access, so opening it is the usual check.
    /// Without it macOS asks folder by folder (Desktop, Documents, Downloads, ...) and hides other apps' data.
    static var fullDiskAccessGranted: Bool {
        let fd = open("/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY)
        guard fd >= 0 else { return false }
        close(fd)
        return true
    }

    /// macOS has no prompt for Full Disk Access: open the pane and show WinSwitch.app so it can be dragged into the list.
    static func requestFullDiskAccess() {
        openSettings(.fullDiskAccess)
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    static func openSettings(_ pane: Pane) {
        NSWorkspace.shared.open(pane.url)
    }
}
