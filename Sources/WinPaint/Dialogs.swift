import AppKit

/// A sheet with OK and Cancel, laid out from rows of label and control.
@MainActor
class DialogSheet: NSObject {
    let panel: NSPanel
    private var completion: ((Bool) -> Void)?

    init(title: String, content: NSView) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        panel.title = title
        let ok = NSButton(title: "OK", target: self, action: #selector(okPressed))
        ok.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed))
        cancel.keyEquivalent = "\u{1b}"
        for b in [ok, cancel] { b.widthAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true }
        let buttons = NSStackView(views: [cancel, ok])
        let stack = NSStackView(views: [content, buttons])
        stack.orientation = .vertical
        stack.alignment = .trailing
        stack.spacing = 18
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 20).isActive = true
        let host = NSView()
        host.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: host.leadingAnchor), stack.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            stack.topAnchor.constraint(equalTo: host.topAnchor), stack.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        panel.contentView = host
    }

    func begin(on window: NSWindow, completion: @escaping (Bool) -> Void) {
        self.completion = completion
        window.beginSheet(panel) { _ in }
        objc_setAssociatedObject(panel, &DialogSheet.key, self, .OBJC_ASSOCIATION_RETAIN)
    }

    nonisolated(unsafe) private static var key = 0

    /// Checked before closing with OK; return false to keep the sheet open.
    func validate() -> Bool { true }

    @objc private func okPressed() {
        guard validate() else { NSSound.beep(); return }
        finish(true)
    }

    @objc private func cancelPressed() { finish(false) }

    private func finish(_ ok: Bool) {
        panel.sheetParent?.endSheet(panel)
        completion?(ok)
        completion = nil
        objc_setAssociatedObject(panel, &DialogSheet.key, nil, .OBJC_ASSOCIATION_RETAIN)
    }

    static func number(_ value: String) -> NSTextField {
        let field = NSTextField(string: value)
        field.alignment = .right
        field.widthAnchor.constraint(equalToConstant: 80).isActive = true
        return field
    }

    static func heading(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        return label
    }
}

/// Image > Resize and skew: by percentage or pixels, keeping the aspect ratio, plus skew in degrees.
final class ResizeSkewSheet: DialogSheet, NSTextFieldDelegate {
    private let original: CGSize
    private let percentage = NSButton(radioButtonWithTitle: "Percentage", target: nil, action: nil)
    private let pixels = NSButton(radioButtonWithTitle: "Pixels", target: nil, action: nil)
    private let horizontal = DialogSheet.number("100")
    private let vertical = DialogSheet.number("100")
    private let keepRatio = NSButton(checkboxWithTitle: "Maintain aspect ratio", target: nil, action: nil)
    private let skewH = DialogSheet.number("0")
    private let skewV = DialogSheet.number("0")

    init(size: CGSize) {
        original = size
        let grid = NSGridView(views: [
            [DialogSheet.heading("Resize"), NSGridCell.emptyContentView],
            [NSTextField(labelWithString: "By:"), NSStackView(views: [percentage, pixels])],
            [NSTextField(labelWithString: "Horizontal:"), horizontal],
            [NSTextField(labelWithString: "Vertical:"), vertical],
            [NSGridCell.emptyContentView, keepRatio],
            [DialogSheet.heading("Skew (Degrees)"), NSGridCell.emptyContentView],
            [NSTextField(labelWithString: "Horizontal:"), skewH],
            [NSTextField(labelWithString: "Vertical:"), skewV],
        ])
        grid.rowSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.row(at: 5).topPadding = 10
        super.init(title: "Resize and Skew", content: grid)
        percentage.state = .on
        keepRatio.state = .on
        for radio in [percentage, pixels] {
            radio.target = self
            radio.action = #selector(unitChanged(_:))
        }
        horizontal.delegate = self
        vertical.delegate = self
    }

    private var byPercentage: Bool { percentage.state == .on }

    @objc private func unitChanged(_ sender: NSButton) {
        percentage.state = sender === percentage ? .on : .off
        pixels.state = sender === pixels ? .on : .off
        if byPercentage {
            horizontal.stringValue = "100"
            vertical.stringValue = "100"
        } else {
            horizontal.stringValue = "\(Int(original.width))"
            vertical.stringValue = "\(Int(original.height))"
        }
    }

    func controlTextDidChange(_ note: Notification) {
        guard keepRatio.state == .on, let field = note.object as? NSTextField, let value = Double(field.stringValue) else { return }
        let other = field === horizontal ? vertical : horizontal
        if byPercentage {
            other.stringValue = field.stringValue
        } else if field === horizontal {
            other.stringValue = "\(Int((value * original.height / original.width).rounded()))"
        } else {
            other.stringValue = "\(Int((value * original.width / original.height).rounded()))"
        }
    }

    /// The new size in pixels and the skew angles, once OK is pressed.
    var result: (width: Int, height: Int, skewH: Double, skewV: Double) {
        let h = Double(horizontal.stringValue) ?? 100, v = Double(vertical.stringValue) ?? 100
        let w = byPercentage ? Int((original.width * h / 100).rounded()) : Int(h)
        let ht = byPercentage ? Int((original.height * v / 100).rounded()) : Int(v)
        return (max(1, w), max(1, ht), Double(skewH.stringValue) ?? 0, Double(skewV.stringValue) ?? 0)
    }

    override func validate() -> Bool {
        let r = result
        return r.width <= 20000 && r.height <= 20000 && abs(r.skewH) <= 89 && abs(r.skewV) <= 89
            && [horizontal, vertical, skewH, skewV].allSatisfy { Double($0.stringValue) != nil }
    }
}

/// File > Image properties: file facts and the canvas size in pixels, inches or centimeters.
final class ImagePropertiesSheet: DialogSheet {
    private let dpi: CGFloat
    private var pixelSize: CGSize
    private let inches = NSButton(radioButtonWithTitle: "Inches", target: nil, action: nil)
    private let centimeters = NSButton(radioButtonWithTitle: "Centimeters", target: nil, action: nil)
    private let pixels = NSButton(radioButtonWithTitle: "Pixels", target: nil, action: nil)
    private let width = DialogSheet.number("")
    private let height = DialogSheet.number("")
    private var unit = 2

    init(size: CGSize, dpi: CGFloat, lastSaved: Date?, fileBytes: Int?) {
        self.dpi = dpi
        pixelSize = size
        let saved = lastSaved.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short) } ?? "Not available"
        let disk = fileBytes.map(ImageFile.sizeText) ?? "Not available"
        let grid = NSGridView(views: [
            [DialogSheet.heading("File attributes"), NSGridCell.emptyContentView],
            [NSTextField(labelWithString: "Last saved:"), NSTextField(labelWithString: saved)],
            [NSTextField(labelWithString: "Size on disk:"), NSTextField(labelWithString: disk)],
            [NSTextField(labelWithString: "Resolution:"), NSTextField(labelWithString: "\(Int(dpi.rounded())) DPI")],
            [DialogSheet.heading("Units"), NSGridCell.emptyContentView],
            [NSGridCell.emptyContentView, NSStackView(views: [inches, centimeters, pixels])],
            [NSTextField(labelWithString: "Width:"), width],
            [NSTextField(labelWithString: "Height:"), height],
        ])
        grid.rowSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.row(at: 4).topPadding = 10
        super.init(title: "Image Properties", content: grid)
        pixels.state = .on
        for (i, radio) in [inches, centimeters, pixels].enumerated() {
            radio.tag = i
            radio.target = self
            radio.action = #selector(unitChanged(_:))
        }
        show()
    }

    private func factor(_ unit: Int) -> CGFloat { unit == 0 ? dpi : unit == 1 ? dpi / 2.54 : 1 }

    private func show() {
        let f = factor(unit)
        func text(_ v: CGFloat) -> String { unit == 2 ? "\(Int(v))" : String(format: "%.2f", v / f) }
        width.stringValue = text(pixelSize.width)
        height.stringValue = text(pixelSize.height)
    }

    @objc private func unitChanged(_ sender: NSButton) {
        if let size = parsed { pixelSize = size }
        unit = sender.tag
        for radio in [inches, centimeters, pixels] { radio.state = radio.tag == unit ? .on : .off }
        show()
    }

    private var parsed: CGSize? {
        guard let w = Double(width.stringValue), let h = Double(height.stringValue) else { return nil }
        let f = factor(unit)
        return CGSize(width: max(1, (CGFloat(w) * f).rounded()), height: max(1, (CGFloat(h) * f).rounded()))
    }

    var result: CGSize { parsed ?? pixelSize }

    override func validate() -> Bool {
        guard let size = parsed else { return false }
        return size.width <= 20000 && size.height <= 20000
    }
}
