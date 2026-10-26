import AppKit

/// Selection, clipboard and Image commands of the canvas.
extension CanvasView: NSMenuItemValidation {
    // MARK: Selection

    /// Lifts the selected pixels so they can move; `clear` leaves Color 2 behind (a Ctrl+drag copy does not).
    func lift(_ selection: Selection, clear: Bool) {
        pushUndo()
        selection.floating = selectedPixels(selection)
        selection.sourceSize = selection.rect.size
        if clear { fillArea(of: selection) }
        floatingCache = nil
        needsDisplay = true
    }

    /// The pixels under a not yet lifted selection, transparent outside a free-form outline.
    private func selectedPixels(_ selection: Selection) -> Bitmap {
        let piece = bitmap.cropped(to: selection.rect)
        guard let mask = selection.mask else { return piece }
        let masked = Bitmap(width: piece.width, height: piece.height, fill: nil)
        masked.context.saveGState()
        masked.context.addPath(mask)
        masked.context.clip(using: .evenOdd)
        masked.draw(piece.makeImage(), in: masked.bounds)
        masked.context.restoreGState()
        return masked
    }

    private func fillArea(of selection: Selection) {
        let ctx = bitmap.context
        ctx.saveGState()
        ctx.setShouldAntialias(false)
        ctx.setBlendMode(.copy)
        ctx.setFillColor(color2.cgColor)
        if let mask = selection.mask {
            ctx.translateBy(x: selection.rect.minX, y: selection.rect.minY)
            ctx.addPath(mask)
            ctx.fillPath(using: .evenOdd)
        } else {
            ctx.fill(selection.rect)
        }
        ctx.restoreGState()
    }

    /// Scales the lifted pixels to the selection's current size so a turn or copy works on what is shown.
    private func settle(_ selection: Selection) {
        guard let floating = selection.floating else { return }
        let w = Int(selection.rect.width), h = Int(selection.rect.height)
        if w != floating.width || h != floating.height {
            selection.floating = floating.transformed(
                width: w, height: h,
                CGAffineTransform(scaleX: CGFloat(w) / CGFloat(floating.width), y: CGFloat(h) / CGFloat(floating.height)))
        }
        selection.sourceSize = selection.rect.size
    }

    func deleteSelection() {
        guard let selection else { return }
        if selection.floating == nil {
            pushUndo()
            fillArea(of: selection)
        }
        self.selection = nil
        controller?.documentChanged()
    }

    @objc func delete(_ sender: Any?) { deleteSelection() }

    @objc override func selectAll(_ sender: Any?) {
        tool = .select
        commitAll()
        selection = Selection(rect: bitmap.bounds)
    }

    func invertSelection() {
        tool = .select
        guard let current = selection else { selectAll(nil); return }
        commitSelection()
        let path = CGMutablePath()
        path.addRect(bitmap.bounds)
        if let mask = current.mask {
            path.addPath(mask, transform: CGAffineTransform(translationX: current.rect.minX, y: current.rect.minY))
        } else {
            path.addRect(current.rect)
        }
        selection = Selection(rect: bitmap.bounds, mask: path)
    }

    func cropToSelection() {
        guard let selection else { return }
        let rect = selection.rect.intersection(bitmap.bounds)
        commitAll()
        guard !rect.isNull, rect.width >= 1, rect.height >= 1 else { return }
        pushUndo()
        replaceBitmap(bitmap.cropped(to: rect))
    }

    func resizeCanvas(width: Int, height: Int) {
        commitAll()
        pushUndo()
        let resized = Bitmap(width: width, height: height, fill: color2)
        resized.draw(bitmap.makeImage(), in: bitmap.bounds)
        replaceBitmap(resized)
    }

    // MARK: Image

    /// Applies an image change to the selection if there is one, else to the whole image.
    private func transform(_ change: (Bitmap) -> Bitmap) {
        commitText()
        commitShape()
        if let selection {
            if selection.floating == nil { lift(selection, clear: true) }
            settle(selection)
            let changed = change(selection.floating!)
            selection.floating = changed
            selection.rect.size = changed.size
            selection.sourceSize = changed.size
            floatingCache = nil
            self.selection = selection
        } else {
            pushUndo()
            replaceBitmap(change(bitmap))
        }
        needsDisplay = true
        controller?.documentChanged()
    }

    func turn(_ turn: Bitmap.Turn) { transform { $0.turned(turn) } }

    func invertColors() {
        transform { b in
            let copy = b.copy()
            copy.invertColors()
            return copy
        }
    }

    /// The size Resize and skew starts from: the selection, else the image.
    var resizeTargetSize: CGSize { selection?.rect.size ?? bitmap.size }

    func resizeAndSkew(width: Int, height: Int, skewH: Double, skewV: Double) {
        let fill = selection == nil ? color2 : nil
        transform { b in
            var out = (width == b.width && height == b.height) ? b : b.resized(width: width, height: height)
            if skewH != 0 || skewV != 0 { out = out.skewed(horizontal: skewH, vertical: skewV, fill: fill) }
            return out
        }
    }

    // MARK: Clipboard

    @objc func copy(_ sender: Any?) {
        guard let selection else { return }
        commitText()
        let image: CGImage
        if selection.floating != nil {
            settle(selection)
            floatingCache = nil
            guard let shown = floatingImage(selection) else { return }
            image = shown
        } else {
            image = selectedPixels(selection).makeImage()
        }
        let rep = NSBitmapImageRep(cgImage: image)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.declareTypes([.png, .tiff], owner: nil)
        if let png = rep.representation(using: .png, properties: [:]) { pasteboard.setData(png, forType: .png) }
        if let tiff = rep.tiffRepresentation { pasteboard.setData(tiff, forType: .tiff) }
    }

    @objc func cut(_ sender: Any?) {
        copy(sender)
        deleteSelection()
    }

    @objc func paste(_ sender: Any?) {
        guard let image = Self.pasteboardImage() else { NSSound.beep(); return }
        pasteImage(image)
    }

    static func pasteboardImage() -> CGImage? {
        let pasteboard = NSPasteboard.general
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pasteboard.data(forType: type),
               let source = CGImageSourceCreateWithData(data as CFData, nil),
               let image = CGImageSourceCreateImageAtIndex(source, 0, nil) { return image }
        }
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let url = urls.first, let image = ImageFile.read(url)?.image { return image }
        if let image = NSImage(pasteboard: pasteboard) {
            var rect = CGRect(origin: .zero, size: image.size)
            return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        }
        return nil
    }

    /// Pastes an image as a floating selection at the top-left of the visible part of the canvas.
    func pasteImage(_ image: CGImage) {
        tool = .select
        commitAll()
        if image.width > bitmap.width || image.height > bitmap.height {
            let alert = NSAlert()
            alert.messageText = "The image you are pasting is larger than the canvas."
            alert.informativeText = "Would you like the canvas to be enlarged?"
            alert.addButton(withTitle: "Yes")
            alert.addButton(withTitle: "No")
            if alert.runModal() == .alertFirstButtonReturn {
                resizeCanvas(width: max(bitmap.width, image.width), height: max(bitmap.height, image.height))
            }
        }
        let corner = imagePoint(visibleRect.origin)
        var x = max(0, floor(corner.x)), y = max(0, floor(corner.y))
        if x + CGFloat(image.width) > CGFloat(bitmap.width) { x = max(0, CGFloat(bitmap.width - image.width)) }
        if y + CGFloat(image.height) > CGFloat(bitmap.height) { y = max(0, CGFloat(bitmap.height - image.height)) }
        pushUndo()
        let pasted = Selection(rect: CGRect(x: x, y: y, width: CGFloat(image.width), height: CGFloat(image.height)))
        pasted.floating = Bitmap(image: image)
        selection = pasted
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)): return canUndo
        case #selector(redo(_:)): return canRedo
        case #selector(cut(_:)), #selector(copy(_:)), #selector(delete(_:)): return selection != nil
        case #selector(paste(_:)):
            return NSPasteboard.general.availableType(from: [.png, .tiff, .fileURL]) != nil
                || NSImage.canInit(with: NSPasteboard.general)
        default: return true
        }
    }

    // MARK: Demo

    /// Draws a sample of every kind of tool, for checking the drawing code without a mouse (--debug-demo).
    func runDemo() {
        func strokeLine(_ kind: StrokeKind, color: NSColor, size: CGFloat, _ points: [CGPoint]) {
            let engine = StrokeEngine(kind: kind, target: bitmap, color: color, size: size, start: points[0])
            for p in points.dropFirst() { engine.extend(to: p) }
        }
        func wave(y: CGFloat, x0: CGFloat = 40) -> [CGPoint] {
            stride(from: 0, through: 220, by: 4).map { CGPoint(x: x0 + CGFloat($0), y: y + sin(CGFloat($0) / 22) * 14) }
        }
        let palette: [NSColor] = [.black, .systemRed, .systemOrange, .systemGreen, .systemBlue, .systemPurple,
                                  .systemTeal, .systemPink, .brown, .darkGray]
        strokeLine(.pencil, color: .black, size: 1, wave(y: 40))
        for (i, brush) in BrushKind.allCases.enumerated() {
            let points = wave(y: 80 + CGFloat(i) * 52)
            if let alpha = brush.layerAlpha {
                let layer = Bitmap(width: bitmap.width, height: bitmap.height, fill: nil)
                let engine = StrokeEngine(kind: .brush(brush), target: layer, color: palette[i], size: 5, start: points[0])
                for p in points.dropFirst() { engine.extend(to: p) }
                bitmap.draw(layer.makeImage(), in: bitmap.bounds, alpha: alpha)
            } else {
                strokeLine(.brush(brush), color: palette[i], size: 5, points)
            }
        }
        let saved = (outlineOn, fillOn, color2)
        tool = .shape
        for (i, kind) in ShapeKind.allCases.filter(\.isBoxed).enumerated() {
            let rect = CGRect(x: 320 + (i % 5) * 92, y: 30 + (i / 5) * 92, width: 80, height: 80)
            fillOn = i % 3 == 0
            color2 = fillOn ? palette[(i + 3) % palette.count] : .white
            pendingShape = PendingShape(kind: kind, rect: rect)
            commitShape()
        }
        fillOn = false
        color2 = .white
        pendingShape = PendingShape(kind: .line, start: CGPoint(x: 330.5, y: 520.5), end: CGPoint(x: 560.5, y: 470.5))
        commitShape()
        curve = (CGPoint(x: 330.5, y: 600.5), CGPoint(x: 560.5, y: 600.5), CGPoint(x: 400.5, y: 520.5),
                 CGPoint(x: 500.5, y: 660.5), 2, false)
        commitShape()
        polygon = [CGPoint(x: 600.5, y: 480.5), CGPoint(x: 700.5, y: 470.5), CGPoint(x: 680.5, y: 600.5), CGPoint(x: 620.5, y: 560.5)]
        commitShape()
        (outlineOn, fillOn, color2) = saved

        bitmap.floodFill(x: 362, y: 72, with: NSColor.systemYellow.pixelValue)
        fontSize = 20
        bold = true
        color1 = .systemBlue
        drawText("Hello from Paint", in: CGRect(x: 800, y: 40, width: 320, height: 40))
        color1 = .black
        bold = false
        fontSize = 11

        tool = .select
        let piece = Selection(rect: CGRect(x: 320, y: 30, width: 190, height: 180))
        selection = piece
        lift(piece, clear: false)
        piece.rect = piece.rect.offsetBy(dx: 520, dy: 380)
        transparentSelection = true
        needsDisplay = true
        controller?.documentChanged()
    }
}
