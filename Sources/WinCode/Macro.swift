import AppKit
import Scintilla

/// Macro > Start Recording / Stop Recording / Playback, on Scintilla's macro recording: every recorded message is
/// replayed as sent. Messages that carry text (typing, paste) keep a copy of it.
@MainActor
final class MacroRecorder {
    struct Step {
        let message: Int32
        let wParam: Int
        let text: String?
        let lParam: Int

        var plist: [String: Any] { ["m": Int(message), "w": wParam, "l": lParam, "t": text ?? NSNull()] }
        init(message: Int32, wParam: Int, text: String?, lParam: Int) {
            self.message = message
            self.wParam = wParam
            self.text = text
            self.lParam = lParam
        }
        init?(_ plist: [String: Any]) {
            guard let m = plist["m"] as? Int, let w = plist["w"] as? Int, let l = plist["l"] as? Int else { return nil }
            self.init(message: Int32(m), wParam: w, text: plist["t"] as? String, lParam: l)
        }
    }

    private weak var window: EditorWindow?
    private(set) var isRecording = false
    private(set) var steps: [Step] = []
    private weak var recordingEditor: ScintillaView?

    init(window: EditorWindow) { self.window = window }

    /// Messages whose lParam is a C string.
    private static let textMessages: Set<Int32> = [SCI_REPLACESEL, SCI_INSERTTEXT, SCI_ADDTEXT, SCI_APPENDTEXT, SCI_SEARCHNEXT, SCI_SEARCHPREV]

    func start() {
        guard let e = window?.editor else { return }
        steps = []
        isRecording = true
        recordingEditor = e
        e.send(SCI_STARTRECORD)
    }

    func stop() {
        recordingEditor?.send(SCI_STOPRECORD)
        isRecording = false
    }

    func record(_ scn: SCNotification) {
        guard isRecording else { return }
        let message = Int32(scn.message)
        var text: String?
        if Self.textMessages.contains(message), scn.lParam != 0, let pointer = UnsafePointer<CChar>(bitPattern: Int(scn.lParam)) {
            text = String(cString: pointer)
        }
        steps.append(Step(message: message, wParam: Int(bitPattern: scn.wParam), text: text, lParam: text == nil ? scn.lParam : 0))
    }

    func play(_ steps: [Step]? = nil, times: Int = 1, untilEnd: Bool = false) {
        guard let e = window?.editor else { return }
        let steps = steps ?? self.steps
        guard !steps.isEmpty else { return }
        e.undoGroup {
            var count = 0
            while untilEnd ? true : count < times {
                let before = (e.currentPos, e.length)
                for step in steps {
                    if let text = step.text { e.send(step.message, step.wParam, text: text) } else { e.send(step.message, step.wParam, step.lParam) }
                }
                count += 1
                // "Run until the end of file": stop when the caret no longer moves or reaches the end.
                if untilEnd && (e.currentPos >= e.length || (e.currentPos, e.length) == before) { break }
                if count > 100_000 { break }
            }
        }
    }

    func saveCurrent(named name: String) {
        var macros = Preferences.savedMacros
        macros[name] = steps.map(\.plist)
        Preferences.savedMacros = macros
    }

    static func saved(_ name: String) -> [Step] {
        (Preferences.savedMacros[name] ?? []).compactMap(Step.init)
    }
}
