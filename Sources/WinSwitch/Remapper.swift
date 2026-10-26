import AppKit
import Carbon.HIToolbox

/// Windows-style keys, ported from the old Karabiner "Windows style" profile. Runs inside the keyboard tap:
/// most rules rewrite the event in place; system shortcuts (screenshots, show desktop) are re-posted at the
/// HID level so macOS handles them as if typed.
@MainActor
final class Remapper {
    /// Marks events we post ourselves so the tap lets them through untouched.
    static let syntheticMarker: Int64 = 0x5753_5743 // "WSWC"

    var onRun: (() -> Void)?
    var onExplorer: (() -> Void)?
    var onClipboard: (() -> Void)?
    var onTaskManager: (() -> Void)?

    static let terminals = ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.",
                                    "net.kovidgoyal.kitty", "org.alacritty", "com.github.wez.wezterm"]

    /// Ctrl+letter becomes Cmd+letter outside terminals (copy, paste, save, find, new tab...).
    private static let ctrlToCmdKeys: Set<Int> = [
        kVK_ANSI_A, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_F, kVK_ANSI_K, kVK_ANSI_L, kVK_ANSI_N, kVK_ANSI_O, kVK_ANSI_P,
        kVK_ANSI_R, kVK_ANSI_S, kVK_ANSI_T, kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X, kVK_ANSI_Z,
        kVK_ANSI_Equal, kVK_ANSI_Minus, kVK_ANSI_0,
    ]

    private static let printScreen = kVK_F13 // PrtSc on a PC keyboard

    /// Returns true when the event was consumed (an action ran instead).
    func handle(type: CGEventType, event: CGEvent) -> Bool {
        guard type == .keyDown || type == .keyUp, Settings.windowsKeysEnabled else { return false }
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let cmd = flags.contains(.maskCommand), ctrl = flags.contains(.maskControl)
        let alt = flags.contains(.maskAlternate), shift = flags.contains(.maskShift)
        let down = type == .keyDown
        let repeating = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

        guard let bundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }
        // Remote desktops and VMs get every key as typed: the remote PC applies its own Windows shortcuts.
        if Settings.passthroughBundlePrefixes.contains(where: { bundleId.hasPrefix($0) }) { return false }
        let inTerminal = Self.terminals.contains { bundleId.hasPrefix($0) }

        // Ctrl+Shift+Esc: Task Manager, from any app.
        if keyCode == kVK_Escape && ctrl && shift && !cmd && !alt {
            if down && !repeating { DispatchQueue.main.async { self.onTaskManager?() } }
            return true
        }

        // Win-key shortcuts: only for the Windows keyboard's Win key (Cmd on the laptop keeps its Mac meaning).
        if HIDMonitor.shared.winKeyDown && cmd && !ctrl && !alt {
            switch (keyCode, shift) {
            case (kVK_ANSI_V, false), (kVK_ANSI_C, false):  // clipboard history
                if down && !repeating && Settings.clipboardHistoryEnabled { DispatchQueue.main.async { self.onClipboard?() } }
                return Settings.clipboardHistoryEnabled
            case (kVK_Space, false):                        // next keyboard language
                if down && !repeating { DispatchQueue.main.async { InputLanguage.next() } }
                return true
            case (kVK_ANSI_E, false):
                if down && !repeating { DispatchQueue.main.async { self.onExplorer?() } }
                return true
            case (kVK_ANSI_R, false):
                if down && !repeating { DispatchQueue.main.async { self.onRun?() } }
                return true
            case (kVK_ANSI_D, false):                       // show desktop / bring the windows back
                if down && !repeating { DispatchQueue.main.async { ShowDesktop.toggle() } }
                return true
            case (kVK_ANSI_L, false):                       // lock
                if down && !repeating { Self.lockScreen() }
                return true
            case (kVK_ANSI_S, true):                        // Win+Shift+S: region to clipboard
                if down && !repeating { Self.post(kVK_ANSI_4, [.maskControl, .maskCommand, .maskShift]) }
                return true
            case (Self.printScreen, false):                 // Win+PrtSc: save the screen to a file
                if down && !repeating { Self.post(kVK_ANSI_3, [.maskCommand, .maskShift]) }
                return true
            default:
                break
            }
        }

        // PrtSc: screen to clipboard. Alt+PrtSc: the active window to clipboard.
        if keyCode == Self.printScreen && !cmd && !ctrl {
            if down && !repeating {
                if alt { Screenshot.frontWindow() } else { Screenshot.screenUnderMouse() }
            }
            return true
        }

        // Alt+F4 quits the app. In our own windows (Explorer, Task Manager) it closes the window instead, so
        // WinSwitch itself keeps running.
        if keyCode == kVK_F4 && alt && !cmd && !ctrl && !shift {
            set(event, flags: [.maskCommand], key: bundleId == "com.kamrat.WinSwitch" ? kVK_ANSI_W : kVK_ANSI_Q)
            return false
        }

        if !inTerminal && remapFunctionKeys(event, bundleId: bundleId, keyCode: keyCode, ctrl: ctrl, cmd: cmd, alt: alt, shift: shift) {
            return false
        }

        if inTerminal {
            remapTerminal(event, keyCode: keyCode, ctrl: ctrl, cmd: cmd, alt: alt, shift: shift)
        } else {
            remapApps(event, keyCode: keyCode, ctrl: ctrl, cmd: cmd, alt: alt, shift: shift)
        }
        return false
    }

    /// Terminals keep Ctrl+C as interrupt; copy and paste use Ctrl+Shift+C / V like Windows Terminal.
    private func remapTerminal(_ event: CGEvent, keyCode: Int, ctrl: Bool, cmd: Bool, alt: Bool, shift: Bool) {
        guard !cmd else { return }
        switch keyCode {
        case kVK_ANSI_V where ctrl && !alt:                         // Ctrl+V and Ctrl+Shift+V paste
            set(event, flags: [.maskCommand], key: kVK_ANSI_V)
        case kVK_ANSI_C where ctrl && shift && !alt:                // Ctrl+Shift+C copies
            set(event, flags: [.maskCommand], key: kVK_ANSI_C)
        case kVK_ANSI_C where ctrl && !alt:                         // Ctrl+C copies a selection, else interrupts
            let isDown = event.type == .keyDown
            let copy = isDown ? Self.hasSelectedText() : copiedOnKeyDown
            copiedOnKeyDown = isDown && copy // reset on every press, even when Ctrl was let go before C
            if copy { set(event, flags: [.maskCommand], key: kVK_ANSI_C) }
        case kVK_Home where !ctrl && !alt && !shift:                // line start / end
            set(event, flags: [.maskControl], key: kVK_ANSI_A)
        case kVK_End where !ctrl && !alt && !shift:
            set(event, flags: [.maskControl], key: kVK_ANSI_E)
        case kVK_LeftArrow where ctrl && !alt && !shift,            // word jump
             kVK_RightArrow where ctrl && !alt && !shift:
            set(event, flags: [.maskAlternate], key: keyCode)
        case kVK_Delete where ctrl && !alt && !shift:               // Ctrl+Backspace deletes a word
            set(event, flags: [.maskControl], key: kVK_ANSI_W)
        default:
            break
        }
    }

    private static let browsers = ["com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser", "org.mozilla.firefox",
                                   "company.thebrowser.", "com.apple.Safari", "com.operasoftware.Opera", "com.vivaldi.Vivaldi"]

    /// Apps that already give F keys their own meaning (and our Explorer, which handles F2 / F5 itself).
    private static let ownFunctionKeys = ["com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.jetbrains.",
                                          "com.apple.dt.Xcode", "com.microsoft.Excel", "com.microsoft.Word",
                                          "com.microsoft.Powerpoint", "com.sublimetext.", "com.kamrat."] // com.kamrat.: WinSwitch, Notepad, Notepad++, MS Paint

    /// Windows F keys: F5 refresh, F2 rename, F12 developer tools, F3 find next, F6 address bar, F11 full screen.
    /// Returns true when the event was rewritten.
    private func remapFunctionKeys(_ event: CGEvent, bundleId: String, keyCode: Int,
                                   ctrl: Bool, cmd: Bool, alt: Bool, shift: Bool) -> Bool {
        guard !cmd, !alt, !Self.ownFunctionKeys.contains(where: { bundleId.hasPrefix($0) }) else { return false }
        let inBrowser = Self.browsers.contains { bundleId.hasPrefix($0) }
        let safari = bundleId == "com.apple.Safari"

        if inBrowser {
            switch keyCode {
            case kVK_F5 where !ctrl && !shift:                      // refresh
                set(event, flags: [.maskCommand], key: kVK_ANSI_R)
            case kVK_F5:                                            // Ctrl+F5 / Shift+F5: refresh without the cache
                set(event, flags: safari ? [.maskCommand, .maskAlternate] : [.maskCommand, .maskShift], key: kVK_ANSI_R)
            case kVK_F12 where !ctrl && !shift,                     // developer tools
                 kVK_ANSI_I where ctrl && shift:
                set(event, flags: [.maskCommand, .maskAlternate], key: kVK_ANSI_I)
            case kVK_ANSI_J where ctrl && shift:                    // console
                set(event, flags: [.maskCommand, .maskAlternate], key: safari ? kVK_ANSI_C : kVK_ANSI_J)
            case kVK_F6 where !ctrl && !shift:                      // address bar
                set(event, flags: [.maskCommand], key: kVK_ANSI_L)
            case kVK_F4 where ctrl && !shift:                       // Ctrl+F4 closes the tab
                set(event, flags: [.maskCommand], key: kVK_ANSI_W)
            default:
                break
            }
            if event.getIntegerValueField(.keyboardEventKeycode) != Int64(keyCode) { return true }
        }

        guard !ctrl else { return false }
        switch keyCode {
        case kVK_F2 where bundleId == "com.apple.finder" && !shift: // rename
            set(event, flags: [], key: kVK_Return)
        case kVK_F3 where bundleId == "com.apple.finder" && !shift: // search
            set(event, flags: [.maskCommand], key: kVK_ANSI_F)
        case kVK_F3:                                                // find next / previous
            set(event, flags: shift ? [.maskCommand, .maskShift] : [.maskCommand], key: kVK_ANSI_G)
        case kVK_F11 where !shift:                                  // full screen
            set(event, flags: [.maskCommand, .maskControl], key: kVK_ANSI_F)
        default:
            return false
        }
        return true
    }

    private func remapApps(_ event: CGEvent, keyCode: Int, ctrl: Bool, cmd: Bool, alt: Bool, shift: Bool) {
        guard !cmd else { return }
        let keepShift: CGEventFlags = shift ? [.maskShift] : []

        if ctrl {
            switch keyCode {
            case kVK_ANSI_Y where !alt && !shift:                   // Ctrl+Y redo
                set(event, flags: [.maskCommand, .maskShift], key: kVK_ANSI_Z)
            case _ where Self.ctrlToCmdKeys.contains(keyCode):      // Ctrl+letter -> Cmd+letter
                set(event, flags: CGEventFlags.maskCommand.union(keepShift).union(alt ? [.maskAlternate] : []), key: keyCode)
            case kVK_Home where !alt:                               // top / bottom of the document
                set(event, flags: CGEventFlags.maskCommand.union(keepShift), key: kVK_UpArrow)
            case kVK_End where !alt:
                set(event, flags: CGEventFlags.maskCommand.union(keepShift), key: kVK_DownArrow)
            case kVK_LeftArrow where !alt, kVK_RightArrow where !alt: // word jump (Shift selects)
                set(event, flags: CGEventFlags.maskAlternate.union(keepShift), key: keyCode)
            case kVK_Delete where !alt && !shift, kVK_ForwardDelete where !alt && !shift: // delete a word
                set(event, flags: [.maskAlternate], key: keyCode)
            default:
                break
            }
            return
        }

        if !alt {
            switch keyCode {
            case kVK_Home:                                          // start / end of the line (Shift selects)
                set(event, flags: CGEventFlags.maskCommand.union(keepShift), key: kVK_LeftArrow)
            case kVK_End:
                set(event, flags: CGEventFlags.maskCommand.union(keepShift), key: kVK_RightArrow)
            default:
                break
            }
        }
    }

    // MARK: Helpers

    /// Whether the last Ctrl+C key-down became a copy, so its key-up is rewritten the same way.
    private var copiedOnKeyDown = false

    /// True when the focused text area (a terminal's buffer) has a selection.
    private static func hasSelectedText() -> Bool {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.1)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.1)
        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selected) == .success else { return false }
        return !((selected as? String) ?? "").isEmpty
    }

    private static let modifierMask: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]

    /// Replaces the modifiers (keeping device flags such as Fn / numeric pad) and the key code.
    private func set(_ event: CGEvent, flags: CGEventFlags, key: Int) {
        var newFlags = event.flags.subtracting(Self.modifierMask).union(flags)
        // Arrow keys carry Fn and numeric-pad flags; letters must not, or apps misread the shortcut.
        if [kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow].contains(key) {
            newFlags.formUnion([.maskSecondaryFn, .maskNumericPad])
        } else {
            newFlags.subtract([.maskSecondaryFn, .maskNumericPad])
        }
        event.flags = newFlags
        event.setIntegerValueField(.keyboardEventKeycode, value: Int64(key))
    }

    /// Types a key combination at the HID level, so macOS system shortcuts (screenshots, show desktop) see it.
    static func post(_ key: Int, _ flags: CGEventFlags) {
        let source = CGEventSource(stateID: .privateState)
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: down) else { continue }
            e.flags = flags
            e.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
            e.post(tap: .cghidEventTap)
        }
    }

    /// Win+L. Uses the private login.framework call the lock-screen menu item uses; falls back to Ctrl+Cmd+Q.
    static func lockScreen() {
        typealias LockFn = @convention(c) () -> Void
        if let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY),
           let symbol = dlsym(handle, "SACLockScreenImmediate") {
            unsafeBitCast(symbol, to: LockFn.self)()
        } else {
            post(kVK_ANSI_Q, [.maskControl, .maskCommand])
        }
    }
}
