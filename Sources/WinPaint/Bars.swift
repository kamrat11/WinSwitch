import AppKit

/// The text options shown under the ribbon while the Text tool is active.
final class TextBar: BackgroundView {
    private weak var canvas: CanvasView?
    private let fontPopup = NSPopUpButton()
    private let sizeBox = NSComboBox()
    private var styleButtons: [NSButton] = []
    private let background = NSSegmentedControl(labels: ["Transparent", "Opaque"], trackingMode: .selectOne, target: nil, action: nil)

    init(canvas: CanvasView) {
        self.canvas = canvas
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 36).isActive = true

        fontPopup.addItems(withTitles: NSFontManager.shared.availableFontFamilies.filter { !$0.hasPrefix(".") })
        fontPopup.target = self
        fontPopup.action = #selector(fontChanged)
        fontPopup.widthAnchor.constraint(equalToConstant: 190).isActive = true

        sizeBox.addItems(withObjectValues: [8, 9, 10, 11, 12, 14, 16, 18, 20, 22, 24, 26, 28, 36, 48, 72].map(String.init))
        sizeBox.target = self
        sizeBox.action = #selector(sizeChanged)
        sizeBox.numberOfVisibleItems = 12
        sizeBox.widthAnchor.constraint(equalToConstant: 64).isActive = true

        for (i, (name, tip)) in [("bold", "Bold"), ("italic", "Italic"), ("underline", "Underline"),
                                 ("strikethrough", "Strikethrough")].enumerated() {
            let button = NSButton(image: symbol(name, size: 13)!, target: self, action: #selector(styleChanged(_:)))
            button.setButtonType(.pushOnPushOff)
            button.bezelStyle = .toolbar
            button.tag = i
            button.toolTip = tip
            styleButtons.append(button)
        }
        background.target = self
        background.action = #selector(backgroundChanged)
        let backgroundLabel = NSTextField(labelWithString: "Background:")

        let fontLabel = NSTextField(labelWithString: "Font:")
        let row = NSStackView(views: [fontLabel, fontPopup, sizeBox] + styleButtons + [backgroundLabel, background])
        row.setCustomSpacing(16, after: sizeBox)
        row.setCustomSpacing(16, after: styleButtons.last!)
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    func refresh() {
        guard let canvas else { return }
        if fontPopup.itemTitles.contains(canvas.fontFamily) {
            fontPopup.selectItem(withTitle: canvas.fontFamily)
        }
        sizeBox.stringValue = String(Int(canvas.fontSize))
        let states = [canvas.bold, canvas.italic, canvas.underline, canvas.strikethrough]
        for (button, on) in zip(styleButtons, states) { button.state = on ? .on : .off }
        background.selectedSegment = canvas.textOpaque ? 1 : 0
    }

    @objc private func fontChanged() { canvas?.fontFamily = fontPopup.titleOfSelectedItem ?? "Arial" }

    @objc private func sizeChanged() {
        if let value = Double(sizeBox.stringValue), value >= 1, value <= 500 { canvas?.fontSize = CGFloat(value) }
        refocusText()
    }

    @objc private func styleChanged(_ sender: NSButton) {
        guard let canvas else { return }
        let on = sender.state == .on
        switch sender.tag {
        case 0: canvas.bold = on
        case 1: canvas.italic = on
        case 2: canvas.underline = on
        default: canvas.strikethrough = on
        }
        refocusText()
    }

    @objc private func backgroundChanged() {
        canvas?.textOpaque = background.selectedSegment == 1
        refocusText()
    }

    private func refocusText() {
        if let view = canvas?.textBox?.view { window?.makeFirstResponder(view) }
    }
}

/// The status bar: cursor position, selection size, canvas size, file size and zoom.
final class StatusBar: BackgroundView {
    private let position = NSTextField(labelWithString: "")
    private let selectionSize = NSTextField(labelWithString: "")
    private let canvasSize = NSTextField(labelWithString: "")
    private let fileSize = NSTextField(labelWithString: "")
    private let zoomLabel = NSTextField(labelWithString: "100%")
    private let slider = NSSlider(value: 0, minValue: -3, maxValue: 3, target: nil, action: nil)
    var onZoom: ((CGFloat) -> Void)?
    var onZoomStep: ((Bool) -> Void)?

    init() {
        super.init(frame: .zero)
        bottomLine = false
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 26).isActive = true

        func item(_ name: String, _ label: NSTextField, width: CGFloat) -> NSStackView {
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.widthAnchor.constraint(equalToConstant: width).isActive = true
            let icon = NSImageView(image: symbol(name, size: 12) ?? NSImage())
            icon.contentTintColor = .secondaryLabelColor
            let stack = NSStackView(views: [icon, label])
            stack.spacing = 5
            return stack
        }
        let left = NSStackView(views: [item("plus.viewfinder", position, width: 110), item("rectangle.dashed", selectionSize, width: 110),
                                       item("square.resize", canvasSize, width: 120), item("doc", fileSize, width: 110)])
        left.spacing = 14

        zoomLabel.font = .systemFont(ofSize: 11)
        zoomLabel.alignment = .right
        zoomLabel.widthAnchor.constraint(equalToConstant: 44).isActive = true
        let minus = RibbonButton(style: .gallery, image: symbol("minus", size: 10), toolTip: "Zoom out")
        minus.action = { [weak self] in self?.onZoomStep?(false) }
        let plus = RibbonButton(style: .gallery, image: symbol("plus", size: 10), toolTip: "Zoom in")
        plus.action = { [weak self] in self?.onZoomStep?(true) }
        slider.controlSize = .small
        slider.target = self
        slider.action = #selector(sliderMoved)
        slider.widthAnchor.constraint(equalToConstant: 120).isActive = true
        let right = NSStackView(views: [zoomLabel, minus, slider, plus])
        right.spacing = 4

        for view in [left, right] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            left.centerYAnchor.constraint(equalTo: centerYAnchor),
            right.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            right.centerYAnchor.constraint(equalTo: centerYAnchor),
            left.trailingAnchor.constraint(lessThanOrEqualTo: right.leadingAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    func update(position p: CGPoint?, selection: CGSize?, canvas: CGSize, fileBytes: Int?, zoom: CGFloat) {
        position.stringValue = p.map { "\(Int(floor($0.x))), \(Int(floor($0.y)))px" } ?? ""
        selectionSize.stringValue = selection.map { "\(Int($0.width)) x \(Int($0.height))px" } ?? ""
        canvasSize.stringValue = "\(Int(canvas.width)) x \(Int(canvas.height))px"
        fileSize.stringValue = fileBytes.map { "Size: " + ImageFile.sizeText($0) } ?? ""
        zoomLabel.stringValue = zoom < 1 && (zoom * 100).rounded() != zoom * 100 ? String(format: "%.1f%%", zoom * 100)
            : "\(Int((zoom * 100).rounded()))%"
        slider.doubleValue = log2(Double(zoom))
    }

    @objc private func sliderMoved() { onZoom?(CGFloat(pow(2, slider.doubleValue))) }
}
