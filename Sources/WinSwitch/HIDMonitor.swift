import AppKit
import IOKit.hid

/// Watches the keyboards directly (needs Input Monitoring permission) so Win-key shortcuts apply only to the Win key
/// of a PC keyboard, not to Cmd on an Apple keyboard. Also implements "Win key alone opens Apps", like the Windows Start menu.
@MainActor
final class HIDMonitor {
    static let shared = HIDMonitor()

    /// Any keyboard not made by Apple counts as a Windows keyboard. To pick one keyboard only, set the defaults
    /// `windowsKeyboardVendor` and `windowsKeyboardProduct` (find the numbers in System Information > USB / Bluetooth).
    private var vendorOverride: Int? { UserDefaults.standard.object(forKey: "windowsKeyboardVendor") as? Int }
    private var productOverride: Int? { UserDefaults.standard.object(forKey: "windowsKeyboardProduct") as? Int }
    private static let appleVendors: Set<Int> = [0x05AC, 0x004C] // USB / internal, Bluetooth

    private func isWindowsKeyboard(_ device: IOHIDDevice) -> Bool {
        let vendor = IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int ?? 0
        let product = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int ?? 0
        if let vendorOverride {
            return vendor == vendorOverride && (productOverride.map { $0 == product } ?? true)
        }
        return !Self.appleVendors.contains(vendor)
    }

    /// True while a Win (GUI) key on the Windows keyboard is held.
    private(set) var winKeyDown = false
    private var winPressedAlone = false
    private var manager: IOHIDManager?

    var onWinAlone: (() -> Void)?

    private init() {
        // A Win key let go while the screen was locked (secure input hides the release) would otherwise stay "down"
        // and turn Cmd+V / Cmd+L on the Apple keyboard into Win shortcuts.
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resetKeys() }
        }
        for name in [NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.didWakeNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.resetKeys() }
            }
        }
    }

    private func resetKeys() {
        winKeyDown = false
        winPressedAlone = false
    }

    static var permissionGranted: Bool { IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted }

    func start() {
        guard manager == nil else { return }
        if !Self.permissionGranted {
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) // adds WinSwitch to Input Monitoring
        }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard,
        ] as CFDictionary)
        IOHIDManagerRegisterInputValueCallback(manager, { context, _, _, value in
            guard let context else { return }
            let me = Unmanaged<HIDMonitor>.fromOpaque(context).takeUnretainedValue()
            let element = IOHIDValueGetElement(value)
            let page = IOHIDElementGetUsagePage(element), usage = IOHIDElementGetUsage(element)
            let pressed = IOHIDValueGetIntegerValue(value) != 0
            let device = IOHIDElementGetDevice(element)
            MainActor.assumeIsolated {
                me.handle(page: page, usage: usage, pressed: pressed, fromWindowsKeyboard: me.isWindowsKeyboard(device))
            }
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if result != kIOReturnSuccess {
            NSLog("WinSwitch: IOHIDManagerOpen failed: \(result) (Input Monitoring permission?)")
        }
        self.manager = manager
    }

    /// Restarts after Input Monitoring is granted (macOS only delivers values to a manager opened with access).
    func restart() {
        if let manager {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        manager = nil
        resetKeys()
        start()
    }

    private func handle(page: UInt32, usage: UInt32, pressed: Bool, fromWindowsKeyboard: Bool) {
        guard page == kHIDPage_KeyboardOrKeypad else { return }
        // Keyboard usages include junk like 0x01 (ErrorRollOver) and 0xFFFFFFFF; only real keys count.
        guard usage >= 0x04 && usage <= 0xE7 else { return }
        let isWin = usage == kHIDUsage_KeyboardLeftGUI || usage == kHIDUsage_KeyboardRightGUI
        if isWin && fromWindowsKeyboard {
            if pressed {
                winKeyDown = true
                winPressedAlone = true
            } else {
                winKeyDown = false
                if winPressedAlone && !KeyboardTap.frontmostIsPassthrough() && Settings.windowsKeysEnabled {
                    onWinAlone?()
                }
                winPressedAlone = false
            }
        } else if pressed {
            winPressedAlone = false
        }
    }

    /// A mouse click while Win is held (Win+click) also cancels "Win alone".
    func cancelWinAlone() { winPressedAlone = false }
}
