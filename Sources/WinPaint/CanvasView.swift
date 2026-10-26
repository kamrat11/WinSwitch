import AppKit

enum Tool: Equatable { case select, pencil, fill, text, eraser, picker, magnifier, brush, shape }
enum SelectionMode { case rectangle, freeForm }

/// The eight drag handles of a box, clockwise from the top-left corner.
enum Handle: Int, CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    func point(in r: CGRect) -> CGPoint {
        switch self {
        case .topLeft: return CGPoint(x: r.minX, y: r.minY)
        case .top: return CGPoint(x: r.midX, y: r.minY)
        case .topRight: return CGPoint(x: r.maxX, y: r.minY)
        case .right: return CGPoint(x: r.maxX, y: r.midY)
        case .bottomRight: return CGPoint(x: r.maxX, y: r.maxY)
        case .bottom: return CGPoint(x: r.midX, y: r.maxY)
        case .bottomLeft: return CGPoint(x: r.minX, y: r.maxY)
        case .left: return CGPoint(x: r.minX, y: r.midY)
        }
    }

    /// The box after dragging this handle by (dx, dy).
    func resize(_ r: CGRect, dx: CGFloat, dy: CGFloat) -> CGRect {
        var minX = r.minX, minY = r.minY, maxX = r.maxX, maxY = r.maxY
        if [.topLeft, .left, .bottomLeft].contains(self) { minX += dx }
        if [.topRight, .right, .bottomRight].contains(self) { maxX += dx }
        if [.topLeft, .top, .topRight].contains(self) { minY += dy }
        if [.bottomLeft, .bottom, .bottomRight].contains(self) { maxY += dy }
        return CGRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY))
    }

    var cursor: NSCursor {
        switch self {
        case .top, .bottom: return .resizeUpDown
        case .left, .right: return .resizeLeftRight
        case .topLeft, .bottomRight: return NSCursor.frameResize(position: .bottomRight, directions: .all)
        case .topRight, .bottomLeft: return NSCursor.frameResize(position: .bottomLeft, directions: .all)
        }
    }
}

/// A selected area. Once moved, resized or turned it floats: its pixels are lifted off the canvas until committed.
@MainActor
final class Selection {
    var rect: CGRect
    /// Free-form outline relative to the selection's origin, in source pixels (even-odd rule).
    var mask: CGPath?
    var floating: Bitmap?
    var sourceSize: CGSize

    init(rect: CGRect, mask: CGPath? = nil) {
        self.rect = rect
        self.mask = mask
        sourceSize = rect.size
    }
}

/// A shape that has been drawn but not yet committed to the canvas, so it can still be moved and resized.
struct PendingShape {
    var kind: ShapeKind
    var rect: CGRect = .zero
    var start: CGPoint = .zero
    var end: CGPoint = .zero
    /// Drawn with the right button: outline in Color 2, fill in Color 1.
    var swapped = false
}

/// The text box of the Text tool while it is being typed in.
@MainActor
final class TextBox {
    var rect: CGRect
    let view: NSTextView
    init(rect: CGRect, view: NSTextView) { self.rect = rect; self.view = view }
}

/// The canvas and the grey workspace around it: draws the image at any zoom and runs the tools.
@MainActor
final class CanvasView: NSView {
    weak var controller: PaintWindowController?

    private(set) var bitmap: Bitmap
    var dpi: CGFloat = 96

    // MARK: Tool settings

    var tool: Tool = .pencil {
        didSet {
            guard tool != oldValue else { return }
            if tool == .picker { previousTool = oldValue }
            commitAll()
            settingsChanged()
        }
    }
    var previousTool: Tool = .pencil
    var selectionMode: SelectionMode = .rectangle { didSet { commitAll(); tool = .select; settingsChanged() } }
    var brush: BrushKind = .brush { didSet { tool = .brush; settingsChanged() } }
    var shapeKind: ShapeKind = .rectangle {
        didSet {
            if var shape = pendingShape, shape.kind.isBoxed, shapeKind.isBoxed {
                shape.kind = shapeKind
                pendingShape = shape
            } else {
                commitAll()
            }
            tool = .shape
            settingsChanged()
        }
    }
    var outlineOn = true { didSet { settingsChanged() } }
    var fillOn = false { didSet { settingsChanged() } }
    var color1: NSColor = .black { didSet { settingsChanged() } }
    var color2: NSColor = .white { didSet { floatingCache = nil; settingsChanged() } }
    /// Which swatch the palette sets: Color 1 or Color 2.
    var editingColor2 = false { didSet { settingsChanged() } }
    var transparentSelection = false { didSet { floatingCache = nil; settingsChanged() } }

    private var sizes: [String: CGFloat] = ["pencil": 1, "eraser": 3, "brush": 3, "shape": 3]
    private var sizeKey: String {
        switch tool {
        case .pencil: return "pencil"
        case .eraser: return "eraser"
        case .shape: return "shape"
        default: return "brush"
        }
    }
    var size: CGFloat {
        get { sizes[sizeKey] ?? 3 }
        set { sizes[sizeKey] = max(1, min(50, newValue.rounded())); settingsChanged() }
    }

    var fontFamily = "Arial" { didSet { textStyleChanged() } }
    var fontSize: CGFloat = 11 { didSet { textStyleChanged() } }
    var bold = false { didSet { textStyleChanged() } }
    var italic = false { didSet { textStyleChanged() } }
    var underline = false { didSet { textStyleChanged() } }
    var strikethrough = false { didSet { textStyleChanged() } }
    var textOpaque = false { didSet { textStyleChanged() } }

    // MARK: View state

    private(set) var zoom: CGFloat = 1
    static let zoomLevels: [CGFloat] = [0.125, 0.25, 0.5, 1, 2, 3, 4, 5, 6, 7, 8]
    var showGrid = false { didSet { needsDisplay = true } }
    /// Where the image's top-left corner is in view coordinates.
    private(set) var origin = CGPoint(x: 10, y: 10)
    let margin: CGFloat = 10

    // MARK: Editing state

    var selection: Selection? { didSet { floatingCache = nil; needsDisplay = true; controller?.updateStatus() } }
    var pendingShape: PendingShape? { didSet { renderOverlay() } }
    var textBox: TextBox?
    var overlay: Bitmap?
    var overlayAlpha: CGFloat = 1
    var polygon: [CGPoint]? { didSet { renderOverlay() } }
    /// The curve being drawn: its ends, its bends, and how many bends are set.
    var curve: (start: CGPoint, end: CGPoint, bend1: CGPoint, bend2: CGPoint, stage: Int, swapped: Bool)? {
        didSet { renderOverlay() }
    }
    var stroke: StrokeEngine?
    var strokeTimer: Timer?
    var drag: Drag?
    var dragSecondary = false
    var mouseImagePoint: CGPoint?
    var canvasResizePreview: CGSize?
    var floatingCache: CGImage?

    enum Drag {
        case canvasResize(Handle)
        case stroke
        case selectRect(CGPoint)
        case lasso([CGPoint])
        case selectionMove(CGPoint, CGRect)
        case selectionHandle(Handle, CGPoint, CGRect)
        case shapeNew(CGPoint)
        case shapeMove(CGPoint, PendingShape)
        case shapeHandle(Handle, CGPoint, PendingShape)
        case lineEnd(Bool)
        case polygon
        case curve
        case textNew(CGPoint)
    }

    // MARK: Undo

    private var undoStack: [CGImage] = []
    private var redoStack: [CGImage] = []
    private var editCount = 0
    private var savedCount = 0
    var isModified: Bool { editCount != savedCount }
    var canUndo: Bool { !undoStack.isEmpty || pendingShape != nil || textBox != nil || polygon != nil || curve != nil }
    var canRedo: Bool { !redoStack.isEmpty && pendingShape == nil && textBox == nil && polygon == nil && curve == nil }

    init(bitmap: Bitmap) {
        self.bitmap = bitmap
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func settingsChanged() {
        if pendingShape != nil || polygon != nil || curve != nil { renderOverlay() }
        controller?.settingsChanged()
        needsDisplay = true
    }

    /// Records the image before an edit, for Undo.
    func pushUndo() {
        undoStack.append(bitmap.makeImage())
        redoStack.removeAll()
        // Keep about 1 GB of history, at least 10 steps.
        while undoStack.count > 10, undoStack.reduce(0, { $0 + $1.width * $1.height * 4 }) > 1_000_000_000 {
            undoStack.removeFirst()
        }
        if savedCount > editCount { savedCount = -1 }
        editCount += 1
        controller?.documentChanged()
    }

    func markSaved() {
        savedCount = editCount
        controller?.documentChanged()
    }

    /// Starts over with a new image and no history.
    func reset(to bitmap: Bitmap) {
        cancelEditing()
        undoStack.removeAll()
        redoStack.removeAll()
        editCount = 0
        savedCount = 0
        replaceBitmap(bitmap)
        controller?.documentChanged()
    }

    func replaceBitmap(_ newBitmap: Bitmap) {
        bitmap = newBitmap
        overlay = nil
        layoutCanvas()
        needsDisplay = true
        controller?.updateStatus()
    }

    /// Drops whatever is being drawn without putting it on the canvas.
    func cancelEditing() {
        pendingShape = nil
        polygon = nil
        curve = nil
        textBox?.view.removeFromSuperview()
        textBox = nil
        selection = nil
        stroke = nil
        strokeTimer?.invalidate()
        drag = nil
        overlay = nil
    }

    @objc func undo(_ sender: Any?) {
        if textBox != nil, window?.firstResponder === textBox?.view, window?.undoManager?.canUndo == true {
            window?.undoManager?.undo()
            return
        }
        if pendingShape != nil || textBox != nil || polygon != nil || curve != nil {
            let hadSelection = selection
            cancelEditing()
            selection = hadSelection
            needsDisplay = true
            return
        }
        selection = nil
        guard let image = undoStack.popLast() else { return }
        redoStack.append(bitmap.makeImage())
        editCount -= 1
        replaceBitmap(Bitmap(image: image))
        controller?.documentChanged()
    }

    @objc func redo(_ sender: Any?) {
        if textBox != nil, window?.firstResponder === textBox?.view, window?.undoManager?.canRedo == true {
            window?.undoManager?.redo()
            return
        }
        guard canRedo, let image = redoStack.popLast() else { return }
        selection = nil
        undoStack.append(bitmap.makeImage())
        editCount += 1
        replaceBitmap(Bitmap(image: image))
        controller?.documentChanged()
    }

    // MARK: Geometry

    var imageRect: CGRect { CGRect(x: origin.x, y: origin.y, width: CGFloat(bitmap.width) * zoom, height: CGFloat(bitmap.height) * zoom) }

    func imagePoint(_ viewPoint: NSPoint) -> CGPoint {
        CGPoint(x: (viewPoint.x - origin.x) / zoom, y: (viewPoint.y - origin.y) / zoom)
    }

    func viewRect(_ r: CGRect) -> CGRect {
        CGRect(x: origin.x + r.minX * zoom, y: origin.y + r.minY * zoom, width: r.width * zoom, height: r.height * zoom)
    }

    func viewPoint(_ p: CGPoint) -> CGPoint { CGPoint(x: origin.x + p.x * zoom, y: origin.y + p.y * zoom) }

    /// Sizes the view to the zoomed image plus a margin, centering the image when it is smaller than the window.
    func layoutCanvas() {
        guard let clip = enclosingScrollView?.contentView else { return }
        let visible = clip.bounds.size
        let w = CGFloat(bitmap.width) * zoom, h = CGFloat(bitmap.height) * zoom
        let needW = w + margin * 2 + 12, needH = h + margin * 2 + 12
        let size = NSSize(width: max(visible.width, needW), height: max(visible.height, needH))
        origin = CGPoint(x: needW < visible.width ? ((visible.width - w) / 2).rounded() : margin,
                         y: needH < visible.height ? ((visible.height - h) / 2).rounded() : margin)
        if frame.size != size { setFrameSize(size) }
        if let textBox { layoutTextBox(textBox) }
        controller?.updateRulers()
        needsDisplay = true
    }

    func setZoom(_ value: CGFloat, around viewAnchor: NSPoint? = nil) {
        let newZoom = max(0.125, min(8, value))
        guard newZoom != zoom, let clip = enclosingScrollView?.contentView else { return }
        let anchor = viewAnchor ?? NSPoint(x: clip.bounds.midX, y: clip.bounds.midY)
        let imageAnchor = imagePoint(anchor)
        let offset = NSPoint(x: anchor.x - clip.bounds.minX, y: anchor.y - clip.bounds.minY)
        zoom = newZoom
        layoutCanvas()
        let target = viewPoint(imageAnchor)
        scroll(NSPoint(x: target.x - offset.x, y: target.y - offset.y))
        controller?.updateStatus()
    }

    func zoomIn(around p: NSPoint? = nil) {
        setZoom(Self.zoomLevels.first { $0 > zoom + 0.001 } ?? 8, around: p)
    }

    func zoomOut(around p: NSPoint? = nil) {
        setZoom(Self.zoomLevels.last { $0 < zoom - 0.001 } ?? 0.125, around: p)
    }

    func zoomToFit() {
        guard let clip = enclosingScrollView?.contentView else { return }
        let fit = min((clip.bounds.width - margin * 2 - 12) / CGFloat(bitmap.width),
                      (clip.bounds.height - margin * 2 - 12) / CGFloat(bitmap.height))
        setZoom(max(0.125, min(8, fit)))
    }

    // MARK: Drawing

    static let workspaceColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.13, green: 0.13, blue: 0.14, alpha: 1)
            : NSColor(srgbRed: 0.89, green: 0.91, blue: 0.94, alpha: 1)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        Self.workspaceColor.setFill()
        dirtyRect.intersection(bounds).fill()

        let r = imageRect
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 6, color: NSColor.black.withAlphaComponent(0.25).cgColor)
        NSColor.white.setFill()
        r.fill()
        ctx.restoreGState()

        ctx.interpolationQuality = zoom >= 1 ? .none : .medium
        ctx.drawFlipped(bitmap.makeImage(), in: r)
        if let overlay {
            ctx.saveGState()
            ctx.setAlpha(overlayAlpha)
            ctx.drawFlipped(overlay.makeImage(), in: r)
            ctx.restoreGState()
        }
        if let selection, let image = floatingImage(selection) {
            ctx.saveGState()
            ctx.clip(to: r)
            ctx.drawFlipped(image, in: viewRect(selection.rect))
            ctx.restoreGState()
        }

        if showGrid && zoom >= 4 { drawGrid(ctx, in: r.intersection(dirtyRect)) }

        if let selection { drawBox(viewRect(selection.rect), handles: true) }
        if case .lasso(let points)? = drag, points.count > 1 {
            let path = NSBezierPath()
            path.move(to: viewPoint(points[0]))
            points.dropFirst().forEach { path.line(to: viewPoint($0)) }
            path.lineWidth = 1
            NSColor.white.setStroke()
            path.stroke()
            path.setLineDash([4, 3], count: 2, phase: 0)
            NSColor.black.setStroke()
            path.stroke()
        }
        if let shape = pendingShape {
            if shape.kind == .line {
                drawHandles(at: [viewPoint(shape.start), viewPoint(shape.end)])
            } else {
                drawBox(viewRect(shape.rect), handles: true)
            }
        }
        if let textBox { drawBox(textBox.view.frame.insetBy(dx: -1, dy: -1), handles: false) }

        let handleRect = r.insetBy(dx: -1, dy: -1)
        for handle in [Handle.right, .bottom, .bottomRight] { drawHandle(at: handle.point(in: handleRect), size: 6) }
        if let preview = canvasResizePreview {
            dashedRect(CGRect(x: r.minX, y: r.minY, width: preview.width * zoom, height: preview.height * zoom))
        }

        if tool == .eraser, let p = mouseImagePoint, drag == nil || stroke != nil {
            let side = size * 2 + 2, half = CGFloat(Int(side) / 2)
            let square = viewRect(CGRect(x: floor(p.x) - half, y: floor(p.y) - half, width: side, height: side))
            NSColor.black.setStroke()
            NSBezierPath(rect: square.insetBy(dx: 0.5, dy: 0.5)).stroke()
        }
    }

    private func drawGrid(_ ctx: CGContext, in area: CGRect) {
        guard !area.isEmpty else { return }
        let first = imagePoint(area.origin), last = imagePoint(NSPoint(x: area.maxX, y: area.maxY))
        ctx.saveGState()
        ctx.setStrokeColor(NSColor(white: 0.5, alpha: 0.45).cgColor)
        ctx.setLineWidth(1 / (window?.backingScaleFactor ?? 2))
        for x in Int(floor(first.x))...Int(ceil(last.x)) {
            let vx = origin.x + CGFloat(x) * zoom
            ctx.move(to: CGPoint(x: vx, y: area.minY)); ctx.addLine(to: CGPoint(x: vx, y: area.maxY))
        }
        for y in Int(floor(first.y))...Int(ceil(last.y)) {
            let vy = origin.y + CGFloat(y) * zoom
            ctx.move(to: CGPoint(x: area.minX, y: vy)); ctx.addLine(to: CGPoint(x: area.maxX, y: vy))
        }
        ctx.strokePath()
        ctx.restoreGState()
    }

    private func dashedRect(_ r: CGRect) {
        let path = NSBezierPath(rect: r.insetBy(dx: -0.5, dy: -0.5))
        path.lineWidth = 1
        NSColor.white.setStroke()
        path.stroke()
        path.setLineDash([4, 3], count: 2, phase: 0)
        NSColor(srgbRed: 0, green: 0.37, blue: 0.72, alpha: 1).setStroke()
        path.stroke()
    }

    private func drawBox(_ r: CGRect, handles: Bool) {
        dashedRect(r)
        if handles { drawHandles(at: Handle.allCases.map { $0.point(in: r.insetBy(dx: -1, dy: -1)) }) }
    }

    private func drawHandles(at points: [CGPoint]) { for p in points { drawHandle(at: p, size: 7) } }

    private func drawHandle(at p: CGPoint, size: CGFloat) {
        let r = CGRect(x: (p.x - size / 2).rounded() + 0.5, y: (p.y - size / 2).rounded() + 0.5, width: size, height: size)
        NSColor.white.setFill()
        r.fill()
        NSColor(srgbRed: 0, green: 0.37, blue: 0.72, alpha: 1).setStroke()
        NSBezierPath(rect: r).stroke()
    }

    /// The selection's pixels as shown: lifted pixels, with Color 2 removed for a transparent selection.
    func floatingImage(_ selection: Selection) -> CGImage? {
        guard let floating = selection.floating else { return nil }
        if let floatingCache { return floatingCache }
        var image = floating.makeImage()
        if transparentSelection {
            let keyed = floating.copy()
            keyed.makeTransparent(color2.pixelValue)
            image = keyed.makeImage()
        }
        floatingCache = image
        return image
    }

    // MARK: Shapes on the overlay

    /// Draws the pending shape, polygon or curve on the overlay, the layer above the image.
    func renderOverlay() {
        guard stroke == nil else { return }
        guard pendingShape != nil || polygon != nil || curve != nil else {
            overlay = nil
            needsDisplay = true
            return
        }
        if overlay == nil || overlay!.width != bitmap.width || overlay!.height != bitmap.height {
            overlay = Bitmap(width: bitmap.width, height: bitmap.height, fill: nil)
        }
        overlay!.clear()
        overlayAlpha = 1
        if let pendingShape { draw(pendingShape, in: overlay!.context) }
        if let polygon { drawPolygon(polygon, closed: false, in: overlay!.context) }
        if let curve { drawCurve(curve, in: overlay!.context) }
        needsDisplay = true
    }

    private func styleColors(swapped: Bool) -> (stroke: NSColor, fill: NSColor) {
        swapped ? (color2, color1) : (color1, color2)
    }

    func draw(_ shape: PendingShape, in ctx: CGContext) {
        let (strokeColor, fillColor) = styleColors(swapped: shape.swapped)
        ctx.saveGState()
        ctx.setLineWidth(size)
        ctx.setStrokeColor(strokeColor.cgColor)
        ctx.setFillColor(fillColor.cgColor)
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        if shape.kind == .line {
            ctx.move(to: shape.start)
            ctx.addLine(to: shape.end)
            ctx.strokePath()
        } else {
            let inset = outlineOn ? min(size / 2, min(shape.rect.width, shape.rect.height) / 2) : 0
            let path = ShapePath.path(shape.kind, in: shape.rect.insetBy(dx: inset, dy: inset))
            if fillOn { ctx.addPath(path); ctx.fillPath(using: .winding) }
            if outlineOn || !fillOn { ctx.addPath(path); ctx.strokePath() }
        }
        ctx.restoreGState()
    }

    func drawPolygon(_ points: [CGPoint], closed: Bool, in ctx: CGContext) {
        guard points.count > 1 else { return }
        let (strokeColor, fillColor) = styleColors(swapped: dragSecondary)
        ctx.saveGState()
        ctx.setLineWidth(size)
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        ctx.setStrokeColor(strokeColor.cgColor)
        ctx.setFillColor(fillColor.cgColor)
        ctx.addLines(between: points)
        if closed {
            ctx.closePath()
            if fillOn {
                let path = ctx.path
                ctx.fillPath(using: .evenOdd)
                if outlineOn, let path { ctx.addPath(path); ctx.strokePath() }
            } else {
                ctx.strokePath()
            }
        } else {
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    func drawCurve(_ c: (start: CGPoint, end: CGPoint, bend1: CGPoint, bend2: CGPoint, stage: Int, swapped: Bool),
                   in ctx: CGContext) {
        ctx.saveGState()
        ctx.setLineWidth(size)
        ctx.setLineCap(.round)
        ctx.setStrokeColor(styleColors(swapped: c.swapped).stroke.cgColor)
        ctx.move(to: c.start)
        ctx.addCurve(to: c.end, control1: c.bend1, control2: c.stage >= 2 ? c.bend2 : c.bend1)
        ctx.strokePath()
        ctx.restoreGState()
    }

    // MARK: Committing

    /// Puts everything still being edited (shape, text, floating selection) on the canvas.
    func commitAll() {
        commitText()
        commitShape()
        commitSelection()
    }

    func commitShape() {
        if let shape = pendingShape {
            pendingShape = nil
            if shape.kind == .line ? shape.start != shape.end : shape.rect.width >= 1 || shape.rect.height >= 1 {
                pushUndo()
                draw(shape, in: bitmap.context)
            }
        }
        if let points = polygon {
            polygon = nil
            if points.count > 1 {
                pushUndo()
                drawPolygon(points, closed: points.count > 2, in: bitmap.context)
            }
        }
        if let c = curve {
            curve = nil
            pushUndo()
            drawCurve(c, in: bitmap.context)
        }
        needsDisplay = true
    }

    func commitSelection() {
        guard let selection else { return }
        if let image = floatingImage(selection) {
            bitmap.draw(image, in: selection.rect)
            controller?.documentChanged()
        }
        self.selection = nil
    }

    // MARK: Text

    func textFont(scale: CGFloat) -> NSFont {
        var traits: NSFontTraitMask = []
        if bold { traits.insert(.boldFontMask) }
        if italic { traits.insert(.italicFontMask) }
        let pixels = fontSize * 96 / 72 * scale
        return NSFontManager.shared.font(withFamily: fontFamily, traits: traits, weight: 5, size: pixels)
            ?? NSFontManager.shared.convert(NSFont.systemFont(ofSize: pixels), toHaveTrait: traits)
    }

    func textAttributes(scale: CGFloat) -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [.font: textFont(scale: scale), .foregroundColor: color1]
        if underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if strikethrough { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        return attrs
    }

    func beginText(in rect: CGRect) {
        let view = NSTextView(frame: viewRect(rect))
        view.isRichText = false
        view.allowsUndo = true
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.minSize = view.frame.size
        view.maxSize = NSSize(width: view.frame.width, height: 100_000)
        view.focusRingType = .none
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        let box = TextBox(rect: rect, view: view)
        textBox = box
        styleTextBox(box)
        addSubview(view)
        window?.makeFirstResponder(view)
        needsDisplay = true
    }

    private func textStyleChanged() {
        if let textBox { styleTextBox(textBox) }
        controller?.settingsChanged()
    }

    private func styleTextBox(_ box: TextBox) {
        let attrs = textAttributes(scale: zoom)
        box.view.typingAttributes = attrs
        box.view.textStorage?.setAttributes(attrs, range: NSRange(location: 0, length: box.view.textStorage?.length ?? 0))
        box.view.insertionPointColor = color1
        box.view.drawsBackground = textOpaque
        box.view.backgroundColor = textOpaque ? color2 : .clear
        needsDisplay = true
    }

    private func layoutTextBox(_ box: TextBox) {
        let frame = viewRect(box.rect)
        box.view.minSize = frame.size
        box.view.maxSize = NSSize(width: frame.width, height: 100_000)
        box.view.frame = frame
        styleTextBox(box)
    }

    func commitText() {
        guard let box = textBox else { return }
        textBox = nil
        let text = box.view.string
        box.view.removeFromSuperview()
        window?.makeFirstResponder(self)
        guard !text.isEmpty else { needsDisplay = true; return }
        pushUndo()
        drawText(text, in: CGRect(x: box.rect.minX, y: box.rect.minY, width: box.rect.width,
                                  height: max(box.rect.height, box.view.frame.height / zoom)))
    }

    func drawText(_ text: String, in rect: CGRect) {
        let ctx = bitmap.context
        if textOpaque {
            ctx.setFillColor(color2.cgColor)
            ctx.fill(rect)
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSAttributedString(string: text, attributes: textAttributes(scale: 1))
            .draw(with: rect, options: [.usesLineFragmentOrigin], context: nil)
        NSGraphicsContext.restoreGraphicsState()
        needsDisplay = true
    }
}
