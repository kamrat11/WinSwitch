import AppKit

/// Mouse, keyboard and drop handling of the canvas: what each tool does with a drag.
extension CanvasView {
    // MARK: Hit testing

    func handle(at vp: NSPoint, in viewBox: CGRect) -> Handle? {
        let box = viewBox.insetBy(dx: -1, dy: -1)
        return Handle.allCases.first { h in
            let p = h.point(in: box)
            return abs(p.x - vp.x) <= 5 && abs(p.y - vp.y) <= 5
        }
    }

    func canvasHandle(at vp: NSPoint) -> Handle? {
        let box = imageRect.insetBy(dx: -1, dy: -1)
        return [Handle.right, .bottom, .bottomRight].first { h in
            let p = h.point(in: box)
            return abs(p.x - vp.x) <= 6 && abs(p.y - vp.y) <= 6
        }
    }

    /// The center of the pixel under a point, where lines are drawn so 1 px lines stay crisp.
    func center(_ p: CGPoint) -> CGPoint { CGPoint(x: floor(p.x) + 0.5, y: floor(p.y) + 0.5) }

    /// The box of whole pixels spanned by two points; `square` makes it a square.
    func pixelBox(_ a: CGPoint, _ b: CGPoint, square: Bool, clamp: Bool) -> CGRect {
        let x0 = floor(a.x), y0 = floor(a.y)
        var x1 = floor(b.x), y1 = floor(b.y)
        if square {
            let d = max(abs(x1 - x0), abs(y1 - y0))
            x1 = x0 + (x1 < x0 ? -d : d)
            y1 = y0 + (y1 < y0 ? -d : d)
        }
        var r = CGRect(x: min(x0, x1), y: min(y0, y1), width: abs(x1 - x0) + 1, height: abs(y1 - y0) + 1)
        if clamp { r = r.intersection(bitmap.bounds) }
        return r.isNull ? .zero : r
    }

    /// Snaps the end of a line to the nearest multiple of 45 degrees.
    func snap45(from a: CGPoint, to b: CGPoint) -> CGPoint {
        let dx = b.x - a.x, dy = b.y - a.y
        let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
        let length = hypot(dx, dy)
        let diagonal = Int((angle / (.pi / 4)).rounded()) % 2 != 0
        let d = diagonal ? max(abs(dx), abs(dy)) * sqrt(2) : length
        return CGPoint(x: (a.x + cos(angle) * d).rounded(.down) + 0.5, y: (a.y + sin(angle) * d).rounded(.down) + 0.5)
    }

    private func viewLocation(_ event: NSEvent) -> NSPoint { convert(event.locationInWindow, from: nil) }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let vp = viewLocation(event)
        var secondary = event.modifierFlags.contains(.control)
        if tool == .select, let selection, viewRect(selection.rect).insetBy(dx: -6, dy: -6).contains(vp) { secondary = false }
        press(event, secondary: secondary)
    }

    override func rightMouseDown(with event: NSEvent) { press(event, secondary: true) }
    override func mouseDragged(with event: NSEvent) { move(event) }
    override func rightMouseDragged(with event: NSEvent) { move(event) }
    override func mouseUp(with event: NSEvent) { release(event) }
    override func rightMouseUp(with event: NSEvent) { release(event) }

    private func press(_ event: NSEvent, secondary: Bool) {
        let vp = viewLocation(event)
        let p = imagePoint(vp)
        if textBox != nil { commitText() }
        window?.makeFirstResponder(self)
        dragSecondary = secondary
        if let h = canvasHandle(at: vp) {
            commitAll()
            drag = .canvasResize(h)
            canvasResizePreview = bitmap.size
            return
        }
        let px = Int(floor(p.x)), py = Int(floor(p.y))
        switch tool {
        case .select:
            pressSelect(p, vp, event)
        case .pencil, .eraser, .brush:
            beginStroke(at: p)
        case .fill:
            let value = (secondary ? color2 : color1).pixelValue
            if bitmap.contains(px, py) && bitmap.pixel(px, py) != value {
                pushUndo()
                bitmap.floodFill(x: px, y: py, with: value)
                needsDisplay = true
            }
        case .picker:
            if bitmap.contains(px, py) {
                let color = NSColor(pixel: bitmap.pixel(px, py))
                if secondary { color2 = color } else { color1 = color }
            }
            tool = previousTool
        case .magnifier:
            if secondary { zoomOut(around: vp) } else { zoomIn(around: vp) }
        case .text:
            drag = .textNew(p)
        case .shape:
            pressShape(p, vp, event, secondary: secondary)
        }
    }

    private func pressSelect(_ p: CGPoint, _ vp: NSPoint, _ event: NSEvent) {
        if let selection {
            let box = viewRect(selection.rect)
            if let h = handle(at: vp, in: box) {
                if selection.floating == nil { lift(selection, clear: true) }
                drag = .selectionHandle(h, p, selection.rect)
                return
            }
            if box.contains(vp) {
                let duplicate = !event.modifierFlags.intersection([.control, .command, .option]).isEmpty
                if selection.floating == nil {
                    lift(selection, clear: !duplicate)
                } else if duplicate, let image = floatingImage(selection) {
                    bitmap.draw(image, in: selection.rect)
                }
                drag = .selectionMove(p, selection.rect)
                return
            }
            commitSelection()
        }
        drag = selectionMode == .freeForm ? .lasso([center(p)]) : .selectRect(p)
    }

    private func pressShape(_ p: CGPoint, _ vp: NSPoint, _ event: NSEvent, secondary: Bool) {
        if let shape = pendingShape {
            if shape.kind == .line {
                let a = viewPoint(shape.start), b = viewPoint(shape.end)
                if hypot(a.x - vp.x, a.y - vp.y) <= 6 { drag = .lineEnd(true); return }
                if hypot(b.x - vp.x, b.y - vp.y) <= 6 { drag = .lineEnd(false); return }
                if distance(vp, toSegment: a, b) <= max(5, size * zoom / 2 + 2) { drag = .shapeMove(p, shape); return }
            } else {
                let box = viewRect(shape.rect)
                if let h = handle(at: vp, in: box) { drag = .shapeHandle(h, p, shape); return }
                if box.contains(vp) { drag = .shapeMove(p, shape); return }
            }
            commitShape()
        }
        let c = center(p)
        switch shapeKind {
        case .polygon:
            if var points = polygon {
                if event.clickCount >= 2 || (points.count > 2 && hypot(c.x - points[0].x, c.y - points[0].y) * zoom < 6) {
                    if points.count > 2, let last = points.last, hypot(last.x - points[points.count - 2].x,
                                                                        last.y - points[points.count - 2].y) < 3 {
                        points.removeLast()
                    }
                    polygon = points
                    commitShape()
                    return
                }
                points.append(c)
                polygon = points
            } else {
                polygon = [c, c]
            }
            drag = .polygon
        case .curve:
            if var current = curve {
                if current.stage == 1 { current.bend1 = c } else { current.bend2 = c }
                curve = current
            } else {
                curve = (c, c, c, c, 0, secondary)
            }
            drag = .curve
        default:
            pendingShape = PendingShape(kind: shapeKind, rect: pixelBox(p, p, square: false, clamp: false),
                                        start: c, end: c, swapped: secondary)
            drag = .shapeNew(p)
        }
    }

    private func distance(_ p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let t = dx == 0 && dy == 0 ? 0 : max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / (dx * dx + dy * dy)))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    private func move(_ event: NSEvent) {
        let vp = viewLocation(event)
        let p = imagePoint(vp)
        let shift = event.modifierFlags.contains(.shift)
        mouseImagePoint = p
        guard let drag else { return }
        autoscroll(with: event)
        switch drag {
        case .canvasResize(let h):
            let w = h == .bottom ? CGFloat(bitmap.width) : max(1, (p.x).rounded())
            let ht = h == .right ? CGFloat(bitmap.height) : max(1, (p.y).rounded())
            canvasResizePreview = CGSize(width: min(w, 20000), height: min(ht, 20000))
        case .stroke:
            stroke?.extend(to: p)
        case .selectRect(let start):
            let box = pixelBox(start, p, square: shift, clamp: true)
            selection = box.width > 0 && box.height > 0 ? Selection(rect: box) : nil
        case .lasso(var points):
            let c = center(CGPoint(x: max(0, min(CGFloat(bitmap.width) - 0.5, p.x)),
                                   y: max(0, min(CGFloat(bitmap.height) - 0.5, p.y))))
            if c != points.last { points.append(c) }
            self.drag = .lasso(points)
        case .selectionMove(let start, let original):
            selection?.rect = original.offsetBy(dx: (p.x - start.x).rounded(), dy: (p.y - start.y).rounded())
        case .selectionHandle(let h, let start, let original):
            var r = h.resize(original, dx: (p.x - start.x).rounded(), dy: (p.y - start.y).rounded())
            r.size = CGSize(width: max(1, r.width), height: max(1, r.height))
            selection?.rect = r
        case .shapeNew(let start):
            guard var shape = pendingShape else { break }
            if shape.kind == .line {
                shape.end = shift ? snap45(from: shape.start, to: p) : center(p)
            } else {
                shape.rect = pixelBox(start, p, square: shift, clamp: false)
            }
            pendingShape = shape
        case .shapeMove(let start, let original):
            let dx = (p.x - start.x).rounded(), dy = (p.y - start.y).rounded()
            var shape = original
            shape.rect = original.rect.offsetBy(dx: dx, dy: dy)
            shape.start = CGPoint(x: original.start.x + dx, y: original.start.y + dy)
            shape.end = CGPoint(x: original.end.x + dx, y: original.end.y + dy)
            pendingShape = shape
        case .shapeHandle(let h, let start, let original):
            var shape = original
            shape.rect = h.resize(original.rect, dx: (p.x - start.x).rounded(), dy: (p.y - start.y).rounded())
            pendingShape = shape
        case .lineEnd(let isStart):
            guard var shape = pendingShape else { break }
            if isStart {
                shape.start = shift ? snap45(from: shape.end, to: p) : center(p)
            } else {
                shape.end = shift ? snap45(from: shape.start, to: p) : center(p)
            }
            pendingShape = shape
        case .polygon:
            guard var points = polygon, points.count > 1 else { break }
            points[points.count - 1] = shift ? snap45(from: points[points.count - 2], to: p) : center(p)
            polygon = points
        case .curve:
            guard var current = curve else { break }
            switch current.stage {
            case 0: current.end = shift ? snap45(from: current.start, to: p) : center(p)
            case 1: current.bend1 = center(p)
            default: current.bend2 = center(p)
            }
            curve = current
        case .textNew:
            break
        }
        needsDisplay = true
        controller?.updateStatus()
    }

    private func release(_ event: NSEvent) {
        let p = imagePoint(viewLocation(event))
        guard let drag else { return }
        self.drag = nil
        switch drag {
        case .canvasResize:
            if let size = canvasResizePreview, size != bitmap.size {
                resizeCanvas(width: Int(size.width), height: Int(size.height))
            }
            canvasResizePreview = nil
        case .stroke:
            endStroke()
        case .selectRect:
            if let selection, selection.rect.width < 1 || selection.rect.height < 1 { self.selection = nil }
        case .lasso(let points):
            guard points.count > 2 else { selection = nil; break }
            let path = CGMutablePath()
            path.addLines(between: points)
            path.closeSubpath()
            let box = path.boundingBoxOfPath.insetBy(dx: -0.5, dy: -0.5).integral.intersection(bitmap.bounds)
            guard !box.isNull, box.width >= 1, box.height >= 1 else { selection = nil; break }
            var shift = CGAffineTransform(translationX: -box.minX, y: -box.minY)
            selection = Selection(rect: box, mask: path.copy(using: &shift))
        case .shapeNew:
            if let shape = pendingShape,
               shape.kind == .line ? shape.start == shape.end : shape.rect.width <= 1 && shape.rect.height <= 1 {
                pendingShape = nil
            }
        case .curve:
            guard var current = curve else { break }
            switch current.stage {
            case 0:
                if current.start == current.end { curve = nil } else { current.stage = 1; curve = current }
            case 1:
                current.stage = 2
                current.bend2 = current.bend1
                curve = current
            default:
                commitShape()
            }
        case .textNew(let start):
            var box = pixelBox(start, p, square: false, clamp: false)
            if box.width < 10 || box.height < 10 {
                box = CGRect(x: floor(start.x), y: floor(start.y), width: 200, height: (fontSize * 96 / 72 * 1.4).rounded())
            }
            beginText(in: box)
        default:
            break
        }
        needsDisplay = true
        controller?.updateStatus()
    }

    // MARK: Freehand strokes

    private func beginStroke(at p: CGPoint) {
        pushUndo()
        let kind: StrokeKind = tool == .pencil ? .pencil : tool == .eraser ? .eraser : .brush(brush)
        let color = tool == .eraser ? (dragSecondary ? color1 : color2) : (dragSecondary ? color2 : color1)
        var target = bitmap
        if case .brush(let b) = kind, let alpha = b.layerAlpha {
            let layer = Bitmap(width: bitmap.width, height: bitmap.height, fill: nil)
            overlay = layer
            overlayAlpha = alpha
            target = layer
        }
        stroke = StrokeEngine(kind: kind, target: target, color: color, size: size, start: p)
        drag = .stroke
        if kind == .brush(.airbrush) {
            strokeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.stroke?.tick()
                    self?.needsDisplay = true
                }
            }
        }
        needsDisplay = true
    }

    private func endStroke() {
        strokeTimer?.invalidate()
        strokeTimer = nil
        if let stroke, stroke.target !== bitmap {
            bitmap.draw(stroke.target.makeImage(), in: bitmap.bounds, alpha: overlayAlpha)
            overlay = nil
        }
        stroke = nil
        controller?.documentChanged()
    }

    // MARK: Hover and cursor

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate,
                                                              .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let vp = viewLocation(event)
        mouseImagePoint = imagePoint(vp)
        cursor(at: vp).set()
        if tool == .eraser { needsDisplay = true }
        controller?.updateStatus()
    }

    override func mouseExited(with event: NSEvent) {
        mouseImagePoint = nil
        NSCursor.arrow.set()
        if tool == .eraser { needsDisplay = true }
        controller?.updateStatus()
    }

    override func cursorUpdate(with event: NSEvent) { cursor(at: viewLocation(event)).set() }

    private func cursor(at vp: NSPoint) -> NSCursor {
        if let h = canvasHandle(at: vp) { return h.cursor }
        if tool == .select, let selection {
            let box = viewRect(selection.rect)
            if let h = handle(at: vp, in: box) { return h.cursor }
            if box.contains(vp) { return .openHand }
        }
        if tool == .shape, let shape = pendingShape, shape.kind != .line {
            let box = viewRect(shape.rect)
            if let h = handle(at: vp, in: box) { return h.cursor }
            if box.contains(vp) { return .openHand }
        }
        if !imageRect.contains(vp) { return .arrow }
        switch tool {
        case .text: return .iBeam
        case .magnifier, .fill, .picker, .pencil, .brush, .shape, .select, .eraser: return .crosshair
        }
    }

    // MARK: Zoom gestures and keys

    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) else { super.scrollWheel(with: event); return }
        let vp = viewLocation(event)
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 40 : event.scrollingDeltaY
        guard abs(delta) > 0.01 else { return }
        if event.hasPreciseScrollingDeltas {
            setZoom(zoom * pow(1.25, delta), around: vp)
        } else if delta > 0 {
            zoomIn(around: vp)
        } else {
            zoomOut(around: vp)
        }
    }

    override func magnify(with event: NSEvent) {
        setZoom(zoom * (1 + event.magnification), around: viewLocation(event))
    }

    override func keyDown(with event: NSEvent) {
        let key = event.charactersIgnoringModifiers?.unicodeScalars.first.map { Int($0.value) } ?? 0
        let control = event.modifierFlags.contains(.control)
        switch key {
        case 27:
            if drag != nil { drag = nil; stroke = nil; canvasResizePreview = nil }
            commitAll()
            needsDisplay = true
        case 127, NSDeleteFunctionKey:
            deleteSelection()
        case NSPageUpFunctionKey where control:
            zoomIn()
        case NSPageDownFunctionKey where control:
            zoomOut()
        case NSLeftArrowFunctionKey, NSRightArrowFunctionKey, NSUpArrowFunctionKey, NSDownArrowFunctionKey:
            guard let selection else { super.keyDown(with: event); return }
            if selection.floating == nil { lift(selection, clear: true) }
            let dx: CGFloat = key == NSLeftArrowFunctionKey ? -1 : key == NSRightArrowFunctionKey ? 1 : 0
            let dy: CGFloat = key == NSUpArrowFunctionKey ? -1 : key == NSDownArrowFunctionKey ? 1 : 0
            selection.rect = selection.rect.offsetBy(dx: dx, dy: dy)
            needsDisplay = true
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: Dropping files

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                               options: [.urlReadingFileURLsOnly: true]) as? [URL])?.first
        else { return false }
        DispatchQueue.main.async { self.controller?.openReplacing(url) }
        return true
    }
}
