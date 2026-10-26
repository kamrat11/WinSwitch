import Carbon

/// Alt+Shift (and Win+Space) switch to the next keyboard language, like Windows.
@MainActor
enum InputLanguage {
    static func next() {
        let filter = [kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
                      kTISPropertyInputSourceIsSelectCapable as String: true] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource],
              list.count > 1 else { return }
        let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
        let currentId = current.flatMap { string($0, kTISPropertyInputSourceID) }
        let index = list.firstIndex { string($0, kTISPropertyInputSourceID) == currentId } ?? -1
        let target = list[(index + 1) % list.count]
        TISSelectInputSource(target)
        HUD.shared.show(string(target, kTISPropertyLocalizedName) ?? "Keyboard", symbol: "globe")
    }

    private static func string(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }
}
