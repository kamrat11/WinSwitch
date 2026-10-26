import AppKit

/// Windows Task Manager colors for each resource.
enum TMColor {
    static let cpu = NSColor(srgbRed: 0.07, green: 0.49, blue: 0.73, alpha: 1)
    static let memory = NSColor(srgbRed: 0.55, green: 0.07, blue: 0.68, alpha: 1)
    static let disk = NSColor(srgbRed: 0.30, green: 0.65, blue: 0.05, alpha: 1)
    static let network = NSColor(srgbRed: 0.65, green: 0.31, blue: 0.00, alpha: 1)
    static let gpu = NSColor(srgbRed: 0.20, green: 0.45, blue: 0.85, alpha: 1)
}

/// A scrolling line graph of the last 60 samples, like the Performance tab. Values are 0...1 unless `autoScale`
/// is on, in which case the graph scales to the largest value shown.
final class GraphView: NSView {
    var color: NSColor = TMColor.cpu { didSet { needsDisplay = true } }
    var showGrid = true
    var autoScale = false
    var capacity = 60
    /// One or two series; the second is drawn dashed (Windows uses that for disk write and network send).
    var series: [[Double]] = [[]] { didSet { needsDisplay = true } }
    /// Filled share under the line, e.g. memory composition; nil fills the area under the first series.
    private(set) var scaleMax: Double = 1

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        NSColor.textBackgroundColor.setFill()
        rect.fill()

        if autoScale {
            let peak = series.flatMap { $0 }.max() ?? 0
            scaleMax = Self.niceCeiling(max(peak, 1))
        } else {
            scaleMax = 1
        }

        if showGrid {
            color.withAlphaComponent(0.14).setStroke()
            let grid = NSBezierPath()
            grid.lineWidth = 1
            for i in 1..<10 {
                let y = rect.minY + rect.height * CGFloat(i) / 10
                grid.move(to: NSPoint(x: rect.minX, y: y)); grid.line(to: NSPoint(x: rect.maxX, y: y))
            }
            for i in 1..<10 {
                let x = rect.minX + rect.width * CGFloat(i) / 10
                grid.move(to: NSPoint(x: x, y: rect.minY)); grid.line(to: NSPoint(x: x, y: rect.maxY))
            }
            grid.stroke()
        }

        let step = rect.width / CGFloat(max(capacity - 1, 1))
        for (index, values) in series.enumerated() where !values.isEmpty {
            let shown = values.suffix(capacity)
            let line = NSBezierPath()
            var first = true
            for (i, value) in shown.enumerated() {
                let x = rect.maxX - CGFloat(shown.count - 1 - i) * step
                let y = rect.minY + rect.height * CGFloat(min(max(value / scaleMax, 0), 1))
                if first { line.move(to: NSPoint(x: x, y: y)); first = false } else { line.line(to: NSPoint(x: x, y: y)) }
            }
            if index == 0 {
                let fill = line.copy() as! NSBezierPath
                fill.line(to: NSPoint(x: rect.maxX, y: rect.minY))
                fill.line(to: NSPoint(x: rect.maxX - CGFloat(shown.count - 1) * step, y: rect.minY))
                fill.close()
                color.withAlphaComponent(0.13).setFill()
                fill.fill()
            } else {
                line.setLineDash([4, 3], count: 2, phase: 0)
            }
            line.lineWidth = showGrid ? 1.3 : 1
            color.setStroke()
            line.stroke()
        }

        color.withAlphaComponent(0.7).setStroke()
        let border = NSBezierPath(rect: rect)
        border.lineWidth = 1
        border.stroke()
    }

    /// 1, 2, 5 x 10^n at or above the value.
    static func niceCeiling(_ value: Double) -> Double {
        let exponent = floor(log10(value))
        let base = pow(10, exponent)
        for m in [1.0, 2, 5, 10] where m * base >= value { return m * base }
        return 10 * base
    }
}

/// The scroll view resizes header views to the standard height; this one keeps its own.
final class FixedHeightHeaderView: NSTableHeaderView {
    var height: CGFloat = 26
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(NSSize(width: newSize.width, height: height)) }
}

/// Header cell with the column's total above its title, like "12% / CPU" in the Processes tab.
final class TotalsHeaderCell: NSTableHeaderCell {
    var heading = ""
    var total = ""
    var alignRight = false
    var sortAscending: Bool?

    override init(textCell string: String) { super.init(textCell: "") }
    required init(coder: NSCoder) { super.init(coder: coder) }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        // Lay out in the part of the header the scroll view actually shows.
        let shown = controlView.visibleRect.intersection(cellFrame)
        let inset = (shown.isEmpty ? cellFrame : shown).insetBy(dx: 6, dy: 1)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignRight ? .right : .left
        paragraph.lineBreakMode = .byTruncatingTail
        let totalAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                                                         .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
        let titleAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10.5),
                                                         .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph]
        // The header view is flipped: the title sits on the bottom line, the total above it.
        (heading as NSString).draw(in: NSRect(x: inset.minX, y: inset.maxY - 13, width: inset.width, height: 14), withAttributes: titleAttrs)
        if !total.isEmpty {
            (total as NSString).draw(in: NSRect(x: inset.minX, y: inset.maxY - 28, width: inset.width, height: 16), withAttributes: totalAttrs)
        }
        if let ascending = sortAscending {
            let arrow = NSImage(systemSymbolName: ascending ? "chevron.up" : "chevron.down", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 8, weight: .semibold))
            if let arrow {
                let size = arrow.size
                arrow.draw(in: NSRect(x: cellFrame.midX - size.width / 2, y: cellFrame.minY + 0.5, width: size.width, height: size.height),
                           from: .zero, operation: .sourceOver, fraction: 0.6, respectFlipped: true, hints: nil)
            }
        }
    }
}

/// A text cell with the Windows "heat map" shading: the busier the value, the warmer the background.
final class HeatCell: NSTableCellView {
    let label = NSTextField(labelWithString: "")
    var heat: Double = 0 { didSet { if heat != oldValue { needsDisplay = true } } }
    /// Resource columns are always lightly shaded, like Windows; busy values get darker.
    var shaded = false { didSet { if shaded != oldValue { needsDisplay = true } } }

    init(identifier: NSUserInterfaceItemIdentifier, alignment: NSTextAlignment) {
        super.init(frame: .zero)
        self.identifier = identifier
        label.alignment = alignment
        label.lineBreakMode = .byTruncatingTail
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard shaded, backgroundStyle != .emphasized else { return }
        let amount = min(1, heat * 1.4)
        NSColor.systemYellow.blended(withFraction: min(1, heat * 1.5), of: .systemOrange)!
            .withAlphaComponent(0.13 + 0.5 * amount).setFill()
        bounds.insetBy(dx: 0, dy: -1).fill()
    }
}

/// Name cell: icon and text.
final class IconCell: NSTableCellView {
    let label = NSTextField(labelWithString: "")
    let icon = NSImageView()

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown
        addSubview(icon)
        addSubview(label)
        textField = label
        imageView = icon
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// Table and outline views that send Delete to the page (End task) and show a per-row context menu.
final class TMTableView: NSTableView {
    var onDelete: (() -> Void)?
    var onEnter: (() -> Void)?
    var menuForRow: ((Int) -> NSMenu?)?

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case 51, 117: onDelete?()          // Delete, Forward Delete
        case 36, 76: onEnter?()             // Return, Enter
        default: super.keyDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return nil }
        if !selectedRowIndexes.contains(row) { selectRowIndexes([row], byExtendingSelection: false) }
        return menuForRow?(row)
    }
}

final class TMOutlineView: NSOutlineView {
    var onDelete: (() -> Void)?
    var menuForRow: ((Int) -> NSMenu?)?

    override func keyDown(with event: NSEvent) {
        if [51, 117].contains(Int(event.keyCode)) { onDelete?() } else { super.keyDown(with: event) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return nil }
        if !selectedRowIndexes.contains(row) { selectRowIndexes([row], byExtendingSelection: false) }
        return menuForRow?(row)
    }
}

@MainActor
enum TMUI {
    static func scroll(_ table: NSView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        return scroll
    }

    static func column(_ id: String, _ title: String, width: CGFloat, right: Bool = false, sortKey: String? = nil) -> NSTableColumn {
        let column = NSTableColumn(identifier: .init(id))
        column.title = title
        column.width = width
        column.minWidth = 40
        let cell = TotalsHeaderCell(textCell: "")
        cell.heading = title
        cell.alignRight = right
        column.headerCell = cell
        column.sortDescriptorPrototype = NSSortDescriptor(key: sortKey ?? id, ascending: !right)
        return column
    }

    static func button(_ title: String, symbol: String, target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(title: title, image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage(),
                              target: target, action: action)
        button.imagePosition = .imageLeading
        button.bezelStyle = .rounded
        button.controlSize = .regular
        return button
    }

    static func label(_ text: String, size: CGFloat = 12, weight: NSFont.Weight = .regular, secondary: Bool = false) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        if secondary { label.textColor = .secondaryLabelColor }
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    /// Sets the column header totals and the sort arrows.
    static func updateHeaders(_ table: NSTableView, totals: [String: String]) {
        let sort = table.sortDescriptors.first
        for column in table.tableColumns {
            guard let cell = column.headerCell as? TotalsHeaderCell else { continue }
            cell.total = totals[column.identifier.rawValue] ?? ""
            cell.sortAscending = sort?.key == column.sortDescriptorPrototype?.key ? sort?.ascending : nil
        }
        table.headerView?.needsDisplay = true
    }

    static func makeHeader(for table: NSTableView, tall: Bool) {
        let header = FixedHeightHeaderView(frame: NSRect(x: 0, y: 0, width: 100, height: tall ? 40 : 26))
        header.height = tall ? 40 : 26
        table.headerView = header
    }

    /// Lets the user show or hide columns from the header's context menu, like Windows.
    static func columnMenu(for table: NSTableView, optional: Set<String>, defaultsKey: String) -> NSMenu {
        let menu = NSMenu()
        let hidden = Set(UserDefaults.standard.stringArray(forKey: defaultsKey) ?? Array(optional))
        for column in table.tableColumns.dropFirst() {
            column.isHidden = hidden.contains(column.identifier.rawValue)
            let item = NSMenuItem(title: (column.headerCell as? TotalsHeaderCell)?.heading ?? column.title,
                                  action: #selector(ColumnToggler.toggle(_:)), keyEquivalent: "")
            item.representedObject = column
            item.target = ColumnToggler.shared
            item.state = column.isHidden ? .off : .on
            menu.addItem(item)
        }
        ColumnToggler.shared.keys[ObjectIdentifier(table)] = defaultsKey
        return menu
    }
}

@MainActor
final class ColumnToggler: NSObject {
    static let shared = ColumnToggler()
    var keys: [ObjectIdentifier: String] = [:]

    @objc func toggle(_ sender: NSMenuItem) {
        guard let column = sender.representedObject as? NSTableColumn, let table = column.tableView else { return }
        column.isHidden.toggle()
        sender.state = column.isHidden ? .off : .on
        if let key = keys[ObjectIdentifier(table)] {
            UserDefaults.standard.set(table.tableColumns.filter(\.isHidden).map(\.identifier.rawValue), forKey: key)
        }
    }
}
