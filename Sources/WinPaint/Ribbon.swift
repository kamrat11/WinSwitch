import AppKit

/// Paint's standard 20 colors, two rows of ten.
let paintPalette: [NSColor] = [
    (0, 0, 0), (127, 127, 127), (136, 0, 21), (237, 28, 36), (255, 127, 39),
    (255, 242, 0), (34, 177, 76), (0, 162, 232), (63, 72, 204), (163, 73, 164),
    (255, 255, 255), (195, 195, 195), (185, 122, 87), (255, 174, 201), (255, 201, 14),
    (239, 228, 176), (181, 230, 29), (153, 217, 234), (112, 146, 190), (200, 191, 231),
].map { NSColor(srgbRed: CGFloat($0.0) / 255, green: CGFloat($0.1) / 255, blue: CGFloat($0.2) / 255, alpha: 1) }

let ribbonBackground = NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(srgbRed: 0.17, green: 0.17, blue: 0.18, alpha: 1)
        : NSColor(srgbRed: 0.975, green: 0.977, blue: 0.98, alpha: 1)
}

/// A view with a solid background color that follows light and dark mode.
class BackgroundView: NSView {
    var color: NSColor = ribbonBackground { didSet { needsDisplay = true } }
    var bottomLine = true
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        bounds.fill()
        if bottomLine {
            NSColor.separatorColor.setFill()
            NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        }
    }
}

/// The toolbar across the top: a File / Edit / View row, then the groups of Windows 11 Paint.
final class Ribbon: BackgroundView {
    private weak var controller: PaintWindowController?
    private var canvas: CanvasView { controller!.canvas }

    private var selectionButton: RibbonButton!
    private var toolButtons: [(Tool, RibbonButton)] = []
    private var brushButton: RibbonButton!
    private var shapeButtons: [(ShapeKind, RibbonButton)] = []
    private var outlineButton: RibbonButton!
    private var fillButton: RibbonButton!
    private var color1View = ColorCircle(toolTip: "Color 1 (foreground color): click here and then select a color from the palette")
    private var color2View = ColorCircle(toolTip: "Color 2 (background color): click here and then select a color from the palette")
    private var customSwatches: [SwatchView] = []
    private var undoButton: RibbonButton!
    private var redoButton: RibbonButton!

    init(controller: PaintWindowController) {
        self.controller = controller
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        let menuRow = NSStackView()
        menuRow.orientation = .horizontal
        menuRow.spacing = 2
        for (title, builder) in [("File", PaintMenus.file), ("Edit", PaintMenus.edit), ("View", PaintMenus.view)] {
            let button = RibbonButton(style: .text, image: nil, title: title, toolTip: nil)
            button.menuProvider = { builder(true) }
            menuRow.addArrangedSubview(button)
        }
        menuRow.addArrangedSubview(divider(height: 18))
        let save = RibbonButton(style: .small, image: symbol("square.and.arrow.down"), toolTip: "Save (Ctrl+S)")
        save.action = { NSApp.sendAction(#selector(PaintWindowController.saveDocument(_:)), to: nil, from: nil) }
        undoButton = RibbonButton(style: .small, image: symbol("arrow.uturn.backward"), toolTip: "Undo (Ctrl+Z)")
        undoButton.action = { [weak self] in self?.canvas.undo(nil) }
        redoButton = RibbonButton(style: .small, image: symbol("arrow.uturn.forward"), toolTip: "Redo (Ctrl+Y)")
        redoButton.action = { [weak self] in self?.canvas.redo(nil) }
        [save, undoButton!, redoButton!].forEach(menuRow.addArrangedSubview)

        let groups = NSStackView()
        groups.orientation = .horizontal
        groups.alignment = .top
        groups.spacing = 6
        let parts: [NSView] = [selectionGroup(), imageGroup(), toolsGroup(), brushesGroup(), shapesGroup(), sizeGroup(), colorsGroup()]
        for (i, part) in parts.enumerated() {
            if i > 0 { groups.addArrangedSubview(divider(height: 78)) }
            groups.addArrangedSubview(part)
        }

        for view in [menuRow, groups] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            menuRow.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            menuRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            groups.topAnchor.constraint(equalTo: menuRow.bottomAnchor, constant: 4),
            groups.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            groups.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            groups.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
        refresh()
    }

    private func divider(height: CGFloat) -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: 1).isActive = true
        box.heightAnchor.constraint(equalToConstant: height).isActive = true
        return box
    }

    /// A group: its controls with the group name centered underneath.
    private func group(_ title: String, _ content: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        let holder = NSView()
        holder.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(content)
        holder.addSubview(label)
        NSLayoutConstraint.activate([
            holder.heightAnchor.constraint(equalToConstant: 84),
            content.topAnchor.constraint(equalTo: holder.topAnchor),
            content.bottomAnchor.constraint(lessThanOrEqualTo: label.topAnchor),
            content.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: holder.leadingAnchor, constant: 2),
            label.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: holder.leadingAnchor),
            label.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
        ])
        return holder
    }

    private func grid(_ rows: [[NSView]], spacing: CGFloat = 2) -> NSGridView {
        let grid = NSGridView(views: rows)
        grid.rowSpacing = spacing
        grid.columnSpacing = spacing
        return grid
    }

    private func vstack(_ views: [NSView], spacing: CGFloat = 2, alignment: NSLayoutConstraint.Attribute = .leading) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.spacing = spacing
        stack.alignment = alignment
        return stack
    }

    // MARK: Groups

    private func selectionGroup() -> NSView {
        selectionButton = RibbonButton(style: .large, image: symbol("rectangle.dashed", size: 24), toolTip: "Selection")
        selectionButton.splitMenu = true
        selectionButton.action = { [weak self] in self?.canvas.tool = .select }
        selectionButton.menuProvider = { [weak self] in self?.selectionMenu() ?? NSMenu() }
        return group("Selection", selectionButton)
    }

    func selectionMenu() -> NSMenu {
        let menu = NSMenu()
        let c = canvas
        menu.addItem(sectionHeader("Selection shapes"))
        menu.addItem(ClosureMenuItem("Rectangle", image: symbol("rectangle.dashed"), checked: c.selectionMode == .rectangle) {
            c.selectionMode = .rectangle
        })
        menu.addItem(ClosureMenuItem("Free-form", image: symbol("lasso"), checked: c.selectionMode == .freeForm) {
            c.selectionMode = .freeForm
        })
        menu.addItem(.separator())
        menu.addItem(sectionHeader("Selection options"))
        menu.addItem(ClosureMenuItem("Select all", image: symbol("checkmark.rectangle")) { c.selectAll(nil) })
        menu.addItem(ClosureMenuItem("Invert selection", image: symbol("rectangle.inset.filled")) { c.invertSelection() })
        menu.addItem(ClosureMenuItem("Delete", image: symbol("trash")) { c.deleteSelection() })
        menu.addItem(ClosureMenuItem("Transparent selection", checked: c.transparentSelection) {
            c.transparentSelection.toggle()
        })
        return menu
    }

    private func sectionHeader(_ title: String) -> NSMenuItem {
        if #available(macOS 14.0, *) { return .sectionHeader(title: title) }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func imageGroup() -> NSView {
        let crop = RibbonButton(style: .small, image: symbol("crop"), toolTip: "Crop (Ctrl+Shift+X)")
        crop.action = { [weak self] in self?.controller?.crop(nil) }
        let resize = RibbonButton(style: .small, image: symbol("arrow.up.left.and.arrow.down.right"), toolTip: "Resize and skew")
        resize.action = { [weak self] in self?.controller?.resizeAndSkew(nil) }
        let rotate = RibbonButton(style: .small, image: symbol("rotate.right"), toolTip: "Rotate")
        rotate.menuProvider = { [weak self] in self?.rotateMenu() ?? NSMenu() }
        let flip = RibbonButton(style: .small, image: symbol("arrow.left.and.right.righttriangle.left.righttriangle.right"),
                                toolTip: "Flip")
        flip.menuProvider = { [weak self] in self?.flipMenu() ?? NSMenu() }
        return group("Image", grid([[crop, resize], [rotate, flip]]))
    }

    func rotateMenu() -> NSMenu {
        let menu = NSMenu()
        let c = canvas
        menu.addItem(ClosureMenuItem("Rotate right 90°", image: symbol("rotate.right")) { c.turn(.right) })
        menu.addItem(ClosureMenuItem("Rotate left 90°", image: symbol("rotate.left")) { c.turn(.left) })
        menu.addItem(ClosureMenuItem("Rotate 180°", image: symbol("arrow.clockwise")) { c.turn(.half) })
        return menu
    }

    func flipMenu() -> NSMenu {
        let menu = NSMenu()
        let c = canvas
        menu.addItem(ClosureMenuItem("Flip vertical", image: symbol("arrow.up.and.down.righttriangle.up.righttriangle.down")) {
            c.turn(.flipVertical)
        })
        menu.addItem(ClosureMenuItem("Flip horizontal", image: symbol("arrow.left.and.right.righttriangle.left.righttriangle.right")) {
            c.turn(.flipHorizontal)
        })
        return menu
    }

    private func toolsGroup() -> NSView {
        let specs: [(Tool, String, String)] = [
            (.pencil, "pencil", "Pencil"), (.fill, "drop.halffull", "Fill with color"), (.text, "textformat", "Text"),
            (.eraser, "eraser", "Eraser"), (.picker, "eyedropper", "Color picker"), (.magnifier, "magnifyingglass", "Magnifier"),
        ]
        for (tool, name, tip) in specs {
            let button = RibbonButton(style: .small, image: symbol(name, size: 16), toolTip: tip)
            button.action = { [weak self] in self?.canvas.tool = tool }
            toolButtons.append((tool, button))
        }
        let b = toolButtons.map(\.1)
        return group("Tools", grid([[b[0], b[1], b[2]], [b[3], b[4], b[5]]]))
    }

    private func brushesGroup() -> NSView {
        brushButton = RibbonButton(style: .large, image: symbol("paintbrush", size: 24), toolTip: "Brushes")
        brushButton.splitMenu = true
        brushButton.action = { [weak self] in self?.canvas.tool = .brush }
        brushButton.menuProvider = { [weak self] in
            let menu = NSMenu()
            guard let c = self?.canvas else { return menu }
            for kind in BrushKind.allCases {
                menu.addItem(ClosureMenuItem(kind.title, image: symbol(kind.symbol), checked: c.brush == kind) { c.brush = kind })
            }
            return menu
        }
        return group("Brushes", brushButton)
    }

    private func shapesGroup() -> NSView {
        var rows: [[NSView]] = [[], [], []]
        for (i, kind) in ShapeKind.allCases.enumerated() {
            let button = RibbonButton(style: .gallery, image: ShapePath.glyph(kind), toolTip: kind.title)
            button.action = { [weak self] in self?.canvas.shapeKind = kind }
            shapeButtons.append((kind, button))
            rows[i / 8].append(button)
        }
        while rows[2].count < 8 { rows[2].append(NSGridCell.emptyContentView) }
        let gallery = grid(rows, spacing: 1)
        let frame = NSBox()
        frame.boxType = .custom
        frame.borderColor = .separatorColor
        frame.borderWidth = 1
        frame.cornerRadius = 4
        frame.fillColor = .controlBackgroundColor
        frame.contentViewMargins = NSSize(width: 2, height: 2)
        frame.contentView = gallery

        outlineButton = RibbonButton(style: .text, image: symbol("pencil.and.outline"), title: "Outline", toolTip: "Shape outline")
        outlineButton.menuProvider = { [weak self] in
            let menu = NSMenu()
            guard let c = self?.canvas else { return menu }
            menu.addItem(ClosureMenuItem("No outline", checked: !c.outlineOn) { c.outlineOn = false })
            menu.addItem(ClosureMenuItem("Solid color", checked: c.outlineOn) { c.outlineOn = true })
            return menu
        }
        fillButton = RibbonButton(style: .text, image: symbol("drop.halffull"), title: "Fill", toolTip: "Shape fill")
        fillButton.menuProvider = { [weak self] in
            let menu = NSMenu()
            guard let c = self?.canvas else { return menu }
            menu.addItem(ClosureMenuItem("No fill", checked: !c.fillOn) { c.fillOn = false })
            menu.addItem(ClosureMenuItem("Solid color", checked: c.fillOn) { c.fillOn = true })
            return menu
        }
        let options = vstack([outlineButton, fillButton])
        let row = NSStackView(views: [frame, options])
        row.alignment = .top
        row.spacing = 6
        return group("Shapes", row)
    }

    private func sizeGroup() -> NSView {
        let button = RibbonButton(style: .large, image: symbol("lineweight", size: 24), toolTip: "Size")
        button.menuProvider = { [weak self] in self?.sizeMenu() ?? NSMenu() }
        return group("Size", button)
    }

    func sizeMenu() -> NSMenu {
        let menu = NSMenu()
        let c = canvas
        for width in [1, 3, 5, 8] {
            let image = NSImage(size: NSSize(width: 64, height: 14), flipped: false) { rect in
                NSColor.black.setFill()
                NSRect(x: 0, y: (rect.midY - CGFloat(width) / 2).rounded(), width: rect.width, height: CGFloat(width)).fill()
                return true
            }
            image.isTemplate = true
            menu.addItem(ClosureMenuItem("\(width)px", image: image, checked: Int(c.size) == width) { c.size = CGFloat(width) })
        }
        menu.addItem(.separator())
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 30))
        let slider = NSSlider(value: Double(c.size), minValue: 1, maxValue: 50, target: nil, action: nil)
        let label = NSTextField(labelWithString: "\(Int(c.size))px")
        slider.frame = NSRect(x: 18, y: 5, width: 130, height: 20)
        label.frame = NSRect(x: 152, y: 6, width: 44, height: 17)
        slider.isContinuous = true
        let relay = SliderRelay { value in
            c.size = CGFloat(value)
            label.stringValue = "\(Int(c.size))px"
        }
        slider.target = relay
        slider.action = #selector(SliderRelay.changed(_:))
        objc_setAssociatedObject(slider, &SliderRelay.key, relay, .OBJC_ASSOCIATION_RETAIN)
        holder.addSubview(slider)
        holder.addSubview(label)
        let item = NSMenuItem()
        item.view = holder
        menu.addItem(item)
        return menu
    }

    private func colorsGroup() -> NSView {
        color1View.action = { [weak self] in self?.canvas.editingColor2 = false }
        color2View.action = { [weak self] in self?.canvas.editingColor2 = true }
        let caption1 = NSTextField(labelWithString: "Color 1"), caption2 = NSTextField(labelWithString: "Color 2")
        for caption in [caption1, caption2] { caption.font = .systemFont(ofSize: 10); caption.textColor = .secondaryLabelColor }
        let wells = NSStackView(views: [vstack([color1View, caption1], spacing: 0, alignment: .centerX),
                                        vstack([color2View, caption2], spacing: 0, alignment: .centerX)])
        wells.alignment = .top
        wells.spacing = 2

        var rows: [[NSView]] = []
        for row in 0..<2 {
            rows.append((0..<10).map { i in swatch(paintPalette[row * 10 + i]) })
        }
        let saved = UserDefaults.standard.stringArray(forKey: "CustomColors") ?? []
        customSwatches = (0..<10).map { i in swatch(i < saved.count ? NSColor(hex: saved[i]) : nil) }
        rows.append(customSwatches)
        let palette = grid(rows, spacing: 3)

        let edit = RibbonButton(style: .large, image: colorWheelImage(), toolTip: "Edit colors")
        edit.keepsImageColors = true
        edit.action = { [weak self] in self?.controller?.editColors() }
        let row = NSStackView(views: [wells, palette, edit])
        row.alignment = .top
        row.spacing = 10
        return group("Colors", row)
    }

    private func swatch(_ color: NSColor?) -> SwatchView {
        let view = SwatchView(color: color)
        view.onPick = { [weak self] color, secondary in
            guard let c = self?.canvas else { return }
            if secondary || c.editingColor2 { c.color2 = color } else { c.color1 = color }
        }
        return view
    }

    /// Puts a color from Edit colors into the custom colors row, newest first.
    func addCustomColor(_ color: NSColor, replacingNewest: Bool) {
        var colors = customSwatches.compactMap(\.color)
        if replacingNewest, !colors.isEmpty { colors.removeFirst() }
        colors.insert(color, at: 0)
        for (i, view) in customSwatches.enumerated() { view.color = i < colors.count ? colors[i] : nil }
        UserDefaults.standard.set(colors.prefix(10).map(\.hexString), forKey: "CustomColors")
    }

    // MARK: State

    func refresh() {
        guard controller != nil else { return }
        let c = canvas
        selectionButton.isSelected = c.tool == .select
        selectionButton.image = symbol(c.selectionMode == .freeForm ? "lasso" : "rectangle.dashed", size: 24)
        for (tool, button) in toolButtons { button.isSelected = c.tool == tool }
        brushButton.isSelected = c.tool == .brush
        brushButton.image = symbol(c.brush.symbol, size: 24)
        brushButton.toolTip = "Brushes: \(c.brush.title)"
        for (kind, button) in shapeButtons { button.isSelected = c.tool == .shape && c.shapeKind == kind }
        color1View.color = c.color1
        color2View.color = c.color2
        color1View.isActive = !c.editingColor2
        color2View.isActive = c.editingColor2
        undoButton.isEnabled = c.canUndo
        redoButton.isEnabled = c.canRedo
    }
}

/// Target for a slider inside a menu.
@MainActor
final class SliderRelay: NSObject {
    nonisolated(unsafe) static var key = 0
    let onChange: (Double) -> Void
    init(_ onChange: @escaping (Double) -> Void) { self.onChange = onChange }
    @objc func changed(_ sender: NSSlider) { onChange(sender.doubleValue) }
}

extension NSColor {
    convenience init?(hex: String) {
        guard hex.count == 6, let v = Int(hex, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? .black
        return String(format: "%02X%02X%02X", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()),
                      Int((c.blueComponent * 255).rounded()))
    }
}
