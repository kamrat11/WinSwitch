import AppKit
import Carbon.HIToolbox

/// Global keyboard and mouse-wheel hook (needs Accessibility permission).
///  - Windows-style keys (Remapper): Ctrl+C/V/X/Z..., Home/End, Ctrl+arrows, PrtSc, Win+E/R/D/L, Alt+F4.
///  - Alt+Tab / Alt+Shift+Tab: window switcher. Release Alt to pick, Esc to cancel.
///    Remote desktops and VMs in front get every key as typed.
///  - Ctrl+Alt+Win+K: Windows-style keys on/off.
///  - Mouse wheel direction reversed for wheel mice (trackpads are left alone).
@MainActor
final class KeyboardTap {
    var onToggleWindowsKeys: (() -> Void)?

    let remapper = Remapper()
    private let switcher: Switcher
    private var tap: CFMachPort?

    init(switcher: Switcher) {
        self.switcher = switcher
    }

    /// Returns false when Accessibility permission is missing.
    /// Alt and Shift are both down and no other key has been pressed since.
    private var altShiftAlone = false

    @discardableResult
    func start() -> Bool {
        if tap != nil { return true }
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .scrollWheel, .leftMouseDown, .rightMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                let me = Unmanaged<KeyboardTap>.fromOpaque(refcon!).takeUnretainedValue()
                return MainActor.assumeIsolated { me.handle(type: type, event: event) }
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    // The run loop source is on the main run loop, so this runs on the main thread.
    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS turns a tap off if a callback is slow; turn it back on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == Remapper.syntheticMarker {
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .scrollWheel:
            return reverseWheelIfNeeded(event) ? nil : Unmanaged.passUnretained(event)
        case .leftMouseDown, .rightMouseDown:
            HIDMonitor.shared.cancelWinAlone() // Win+click is not "Win alone"
            altShiftAlone = false              // nor is Alt+Shift+click a language switch
            return Unmanaged.passUnretained(event)
        default:
            break
        }

        let flags = event.flags
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let alt = flags.contains(.maskAlternate)
        let cmd = flags.contains(.maskCommand)
        let ctrl = flags.contains(.maskControl)
        let shift = flags.contains(.maskShift)

        if type == .flagsChanged {
            if switcher.isShowing && !alt {
                switcher.commit()
            }
            // Alt+Shift pressed and released with no other key in between switches the keyboard language.
            if alt && shift && !cmd && !ctrl {
                altShiftAlone = true
            } else if altShiftAlone && !(alt && shift) {
                altShiftAlone = false
                if !cmd, !ctrl, Settings.windowsKeysEnabled, !Self.frontmostIsPassthrough() {
                    DispatchQueue.main.async { InputLanguage.next() }
                }
            }
            return Unmanaged.passUnretained(event)
        }
        if type == .keyDown { altShiftAlone = false }

        // Ctrl+Alt+Win+K toggles the Windows-style keys.
        if keyCode == kVK_ANSI_K && ctrl && alt && cmd {
            if type == .keyDown && event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                DispatchQueue.main.async { self.onToggleWindowsKeys?() }
            }
            return nil
        }

        // While the switcher is open it owns the keyboard.
        if switcher.isShowing {
            if type == .keyDown {
                switch keyCode {
                case kVK_Tab: switcher.step(shift ? -1 : 1)
                case kVK_RightArrow, kVK_DownArrow: switcher.step(1)
                case kVK_LeftArrow, kVK_UpArrow: switcher.step(-1)
                case kVK_Escape: switcher.cancel()
                case kVK_Return, kVK_ANSI_KeypadEnter, kVK_Space: switcher.commit()
                case kVK_ANSI_W, kVK_F4: switcher.closeSelected()
                default: break
                }
            }
            return nil
        }

        // Alt+Tab opens the switcher, unless a remote desktop / VM is in front: it gets the keys itself.
        if type == .keyDown && keyCode == kVK_Tab && alt && !cmd && !ctrl && Settings.switcherEnabled {
            if Self.frontmostIsPassthrough() {
                return Unmanaged.passUnretained(event)
            }
            switcher.open(reverse: shift)
            return nil
        }

        if remapper.handle(type: type, event: event) {
            return nil
        }
        return Unmanaged.passUnretained(event)
    }

    /// Wheel mice scroll the Windows way round; trackpad / Magic Mouse scrolling is untouched. Gestures carry a
    /// scroll or momentum phase and wheels never do (high-resolution wheels such as Logitech's still report
    /// "continuous", so that flag can't tell them apart). Returns true when the event was replaced by a new one.
    ///
    /// Flipping the deltas in place is not enough: the event still carries the device data and the "natural
    /// scrolling" mark, and apps that read those (Terminal, some Electron and Java apps) undo the flip. So the wheel
    /// event is dropped and a fresh one, already scrolling the Windows way and without that baggage, is posted.
    private func reverseWheelIfNeeded(_ event: CGEvent) -> Bool {
        guard Settings.reverseMouseWheel,
              event.getIntegerValueField(.scrollWheelEventScrollPhase) == 0,
              event.getIntegerValueField(.scrollWheelEventMomentumPhase) == 0 else { return false }

        // Remote desktops and VMs get the reversed wheel too: macOS has already applied natural scrolling before they
        // see it, so passing it through untouched would scroll the remote PC backwards.

        let lines = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let points = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
        let fixed = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        guard let fresh = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                  wheel1: Int32(clamping: -points), wheel2: 0, wheel3: 0) else { return false }
        fresh.location = event.location
        fresh.flags = event.flags
        // Same amounts as the original, vertical reversed; horizontal (tilt wheels, Shift+wheel) as it was.
        fresh.setIntegerValueField(.scrollWheelEventIsContinuous, value: event.getIntegerValueField(.scrollWheelEventIsContinuous))
        fresh.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: -lines)
        fresh.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: -points)
        fresh.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: -fixed)
        fresh.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: event.getIntegerValueField(.scrollWheelEventDeltaAxis2))
        fresh.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2))
        fresh.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2))
        fresh.setIntegerValueField(.eventSourceUserData, value: Remapper.syntheticMarker)
        fresh.post(tap: .cgSessionEventTap)
        return true
    }

    /// Checked on every key press (never cached), so it follows focus into remote desktop session windows.
    static func frontmostIsPassthrough() -> Bool {
        guard let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }
        return Settings.passthroughBundlePrefixes.contains { id.hasPrefix($0) }
    }
}
