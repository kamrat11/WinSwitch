import AppKit

/// Notepad's status bar: "Ln 1, Col 1 | 12 characters" on the left, "100% | Windows (CRLF) | UTF-8" on the right.
/// The line ending and encoding are buttons that open a menu to change them.
@MainActor
final class StatusBar: NSView {
    private let position = StatusBar.label()
    private let characters = StatusBar.label()
    private let zoom = StatusBar.label()
    let lineEnding = StatusBar.button()
    let encoding = StatusBar.button()

    init() {
        super.init(frame: .zero)
        let left = NSStackView(views: [position, StatusBar.separator(), characters])
        let right = NSStackView(views: [zoom, StatusBar.separator(), lineEnding, StatusBar.separator(), encoding])
        position.widthAnchor.constraint(greaterThanOrEqualToConstant: 110).isActive = true
        zoom.alignment = .right
        zoom.widthAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
        for stack in [left, right] {
            stack.spacing = 12
            stack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stack)
        }
        let border = NSBox()
        border.boxType = .separator
        border.translatesAutoresizingMaskIntoConstraints = false
        addSubview(border)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),
            border.topAnchor.constraint(equalTo: topAnchor),
            border.leadingAnchor.constraint(equalTo: leadingAnchor),
            border.trailingAnchor.constraint(equalTo: trailingAnchor),
            left.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            left.centerYAnchor.constraint(equalTo: centerYAnchor),
            right.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            right.centerYAnchor.constraint(equalTo: centerYAnchor),
            right.leadingAnchor.constraint(greaterThanOrEqualTo: left.trailingAnchor, constant: 12),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(line: Int, column: Int, selected: Int, total: Int, zoomPercent: Int,
                lineEnding ending: LineEnding, encoding enc: TextEncoding) {
        position.stringValue = "Ln \(line), Col \(column)"
        let count = { (n: Int) in n.formatted(.number) }
        characters.stringValue = selected > 0 ? "\(count(selected)) of \(count(total)) characters"
            : "\(count(total)) character\(total == 1 ? "" : "s")"
        zoom.stringValue = "\(zoomPercent)%"
        lineEnding.title = ending.title
        encoding.title = enc.title
    }

    private static func label() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        return label
    }

    private static func button() -> NSButton {
        let button = NSButton(title: "", target: nil, action: nil)
        button.isBordered = false
        button.font = .systemFont(ofSize: 12)
        button.contentTintColor = .secondaryLabelColor
        return button
    }

    private static func separator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 14).isActive = true
        line.widthAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }
}
