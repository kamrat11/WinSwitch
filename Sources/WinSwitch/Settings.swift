import Foundation

/// User settings, stored in UserDefaults (domain com.kamrat.WinSwitch).
enum Settings {
    private static let defaults = UserDefaults.standard

    enum DockActivation: String, CaseIterable {
        case hover          // show previews when the mouse rests on a Dock icon
        case hoverWithOption // only while Option (Alt) is held
        case off

        var title: String {
            switch self {
            case .hover: return "On hover"
            case .hoverWithOption: return "On hover while holding Alt"
            case .off: return "Off"
            }
        }
    }

    /// Windows-style keys (Remapper). Ctrl+Alt+Win+K toggles it.
    static var windowsKeysEnabled: Bool {
        get { defaults.object(forKey: "windowsKeysEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "windowsKeysEnabled") }
    }

    /// Wheel mice scroll the opposite way to the trackpad, like Windows.
    static var reverseMouseWheel: Bool {
        get { defaults.object(forKey: "reverseMouseWheel") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "reverseMouseWheel") }
    }

    /// Clipboard history (Win+V).
    static var clipboardHistoryEnabled: Bool {
        get { defaults.object(forKey: "clipboardHistoryEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "clipboardHistoryEnabled") }
    }

    static var switcherEnabled: Bool {
        get { defaults.object(forKey: "switcherEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "switcherEnabled") }
    }

    static var dockActivation: DockActivation {
        get { DockActivation(rawValue: defaults.string(forKey: "dockActivation") ?? "") ?? .hover }
        set { defaults.set(newValue.rawValue, forKey: "dockActivation") }
    }

    /// Delay before Dock previews appear, in seconds.
    static var dockHoverDelay: Double {
        get { defaults.object(forKey: "dockHoverDelay") as? Double ?? 0.35 }
        set { defaults.set(newValue, forKey: "dockHoverDelay") }
    }

    /// Apps whose windows get Alt+Tab themselves (remote desktops and VMs). Prefix match on bundle id.
    static var passthroughBundlePrefixes: [String] {
        get {
            defaults.stringArray(forKey: "passthroughBundlePrefixes") ?? [
                "com.microsoft.rdc",       // Windows App / Microsoft Remote Desktop
                "com.parallels.",
                "com.vmware.fusion",
                "com.utmapp.",
                "com.apple.ScreenSharing",
                "com.teamviewer.",
                "org.virtualbox.app.VirtualBoxVM",
                "com.citrix.",
            ]
        }
        set { defaults.set(newValue, forKey: "passthroughBundlePrefixes") }
    }

    /// Apps never listed in the switcher or Dock previews: WinSwitch itself plus the bundle ids in the
    /// `excludedBundleIds` default (`defaults write com.kamrat.WinSwitch excludedBundleIds -array com.apple.Music`).
    static var hiddenBundleIds: Set<String> {
        Set(["com.kamrat.WinSwitch"] + (defaults.stringArray(forKey: "excludedBundleIds") ?? []))
    }
}
