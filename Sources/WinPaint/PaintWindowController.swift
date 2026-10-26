import AppKit
import WinDialogs
import UniformTypeIdentifiers

/// One Paint window: the ribbon, the canvas in its workspace, the status bar, and the file it shows.
@MainActor
final class PaintWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    let canvas: CanvasView
    private let scrollView = NSScrollView()
    private var ribbon: Ribbon!
    private var textBar: TextBar!
    private let statusBar = StatusBar()

    private(set) var fileURL: URL?
    private var lastSaved: Date?
    private var fileBytes: Int?
    private var colorSessionStarted = false

    static let defaultSize = (width: 1152, height: 648)

    /// An untitled window nobody has drawn in yet, which opening a file can reuse.
    var isPristine: Bool { fileURL == nil && !canvas.isModified }
    var displayName: String { fileURL?.lastPathComponent ?? "Untitled" }

    init() {
        canvas = CanvasView(bitmap: Bitmap(width: Self.defaultSize.width, height: Self.defaultSize.height))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 900),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.minSize = NSSize(width: 640, height: 420)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        canvas.controller = self
        ribbon = Ribbon(controller: self)
        textBar = TextBar(canvas: canvas)
        buildLayout(in: window)
        window.center()
        updateTitle()
        settingsChanged()
        updateStatus()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildLayout(in window: NSWindow) {
        scrollView.documentView = canvas
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = CanvasView.workspaceColor
        scrollView.hasHorizontalRuler = true
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = false
        for ruler in [scrollView.horizontalRulerView, scrollView.verticalRulerView].compactMap({ $0 }) {
            ruler.reservedThicknessForMarkers = 0
            ruler.reservedThicknessForAccessoryView = 0
            ruler.clientView = canvas
            ruler.clipsToBounds = true
        }
        scrollView.clipsToBounds = true
        scrollView.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scrollView.contentView,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.canvas.layoutCanvas() }
        }

        statusBar.onZoom = { [weak self] zoom in self?.canvas.setZoom(zoom) }
        statusBar.onZoomStep = { [weak self] zoomIn in if zoomIn { self?.canvas.zoomIn() } else { self?.canvas.zoomOut() } }

        let stack = NSStackView(views: [ribbon, textBar, scrollView, statusBar])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        stack.distribution = .fill
        for view in [ribbon!, textBar!, scrollView, statusBar] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        window.contentView = stack
        DispatchQueue.main.async { self.canvas.layoutCanvas() }
    }

    // MARK: State from the canvas

    func settingsChanged() {
        ribbon?.refresh()
        textBar?.refresh()
        textBar?.isHidden = canvas.tool != .text
    }

    func documentChanged() {
        updateTitle()
        ribbon?.refresh()
        updateStatus()
    }

    private func updateTitle() {
        window?.title = "\(displayName) - Paint"
        window?.isDocumentEdited = canvas.isModified
    }

    func updateStatus() {
        let bitmap = canvas.bitmap
        var position = canvas.mouseImagePoint
        if let p = position, !bitmap.contains(Int(floor(p.x)), Int(floor(p.y))) { position = nil }
        let selection = canvas.selection?.rect.size ?? canvas.pendingShape.flatMap { $0.kind == .line ? nil : $0.rect.size }
        statusBar.update(position: position, selection: selection, canvas: bitmap.size, fileBytes: fileBytes, zoom: canvas.zoom)
    }

    func updateRulers() {
        let zoom = canvas.zoom
        let name = NSRulerView.UnitName("WinPaintPixels\(Int(zoom * 1000))")
        NSRulerView.registerUnit(withName: name, abbreviation: "px", unitToPointsConversionFactor: zoom,
                                 stepUpCycle: [2, 2.5], stepDownCycle: [0.5, 0.2])
        if let ruler = scrollView.horizontalRulerView {
            ruler.measurementUnits = name
            ruler.originOffset = canvas.origin.x
        }
        if let ruler = scrollView.verticalRulerView {
            ruler.measurementUnits = name
            ruler.originOffset = canvas.origin.y
        }
    }

    // MARK: Files

    /// Asks "Do you want to save changes" when there are unsaved changes; false means Cancel.
    func confirmDiscard() -> Bool {
        guard canvas.isModified else { return true }
        window?.makeKeyAndOrderFront(nil)
        let alert = NSAlert()
        alert.messageText = "Do you want to save changes to \(displayName)?"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save()
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }

    func load(_ url: URL) {
        guard let (image, dpi) = ImageFile.read(url) else {
            let alert = NSAlert()
            alert.messageText = "Paint cannot read this file."
            alert.informativeText = "\(url.path)\n\nThis is not a valid bitmap file, or its format is not currently supported."
            alert.runModal()
            return
        }
        canvas.reset(to: Bitmap(image: image))
        canvas.dpi = dpi
        fileURL = url
        readFileFacts()
        AppDelegate.shared.noteRecent(url)
        canvas.setZoom(1)
        window?.contentView?.layoutSubtreeIfNeeded()
        canvas.layoutCanvas()
        if let clip = scrollView.contentView as NSClipView?,
           CGFloat(image.width) > clip.bounds.width - 40 || CGFloat(image.height) > clip.bounds.height - 40 {
            canvas.zoomToFit()
        }
        documentChanged()
    }

    func openReplacing(_ url: URL) {
        guard confirmDiscard() else { return }
        load(url)
    }

    private func readFileFacts() {
        guard let url = fileURL, let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else {
            lastSaved = nil
            fileBytes = nil
            return
        }
        lastSaved = values.contentModificationDate
        fileBytes = values.fileSize
    }

    @discardableResult func save() -> Bool {
        if let url = fileURL, let format = ImageFormat.forURL(url) { return write(to: url, format: format) }
        return saveAs(format: nil)
    }

    @discardableResult func saveAs(format preset: ImageFormat?) -> Bool {
        let format = preset ?? fileURL.flatMap(ImageFormat.forURL) ?? .png
        let dialog = SaveDialog()
        dialog.title = "Save as"
        dialog.types = ImageFormat.allCases.map { SaveDialog.FileType($0.title, [$0.fileExtension]) }
        dialog.typeIndex = format.rawValue
        dialog.fileName = (fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled") + "." + format.fileExtension
        dialog.directory = fileURL?.deletingLastPathComponent() ?? FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
        dialog.rememberKey = "saveFolder"
        guard let result = dialog.run() else { return false }
        // The extension typed wins over the type list, like Paint ("photo.jpg" saves a JPEG).
        let chosen = ImageFormat.forURL(result.url) ?? ImageFormat(rawValue: result.typeIndex) ?? .png
        return write(to: result.url, format: chosen)
    }

    private func write(to url: URL, format: ImageFormat) -> Bool {
        canvas.commitAll()
        do {
            try ImageFile.write(canvas.bitmap.makeImage(), to: url, format: format, dpi: canvas.dpi)
        } catch {
            NSAlert(error: error).runModal()
            return false
        }
        fileURL = url
        canvas.markSaved()
        readFileFacts()
        AppDelegate.shared.noteRecent(url)
        documentChanged()
        return true
    }

    // MARK: File menu

    @objc func newDocument(_ sender: Any?) {
        guard confirmDiscard() else { return }
        canvas.reset(to: Bitmap(width: Self.defaultSize.width, height: Self.defaultSize.height))
        canvas.dpi = 96
        fileURL = nil
        readFileFacts()
        canvas.setZoom(1)
        documentChanged()
    }

    @objc func openDocument(_ sender: Any?) {
        guard confirmDiscard() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.directoryURL = fileURL?.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(url)
    }

    @objc func saveDocument(_ sender: Any?) { save() }
    @objc func saveDocumentAs(_ sender: Any?) { saveAs(format: nil) }

    @objc func saveAsFormat(_ sender: NSMenuItem) { saveAs(format: ImageFormat(rawValue: sender.tag)) }

    @objc func printImage(_ sender: Any?) {
        canvas.commitAll()
        let image = canvas.bitmap.makeImage()
        let scale = 72 / canvas.dpi
        let view = PrintImageView(image: image, size: NSSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale))
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.horizontalPagination = .fit
        info.verticalPagination = .fit
        info.isHorizontallyCentered = true
        info.isVerticallyCentered = true
        info.orientation = image.width > image.height ? .landscape : .portrait
        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.jobTitle = displayName
        if let window { operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil) } else { operation.run() }
    }

    @objc func pageSetup(_ sender: Any?) {
        NSPageLayout().runModal(with: NSPrintInfo.shared)
    }

    /// Fill, tile or center the picture as the desktop background of every screen.
    @objc func setDesktopBackground(_ sender: NSMenuItem) {
        canvas.commitAll()
        let image = canvas.bitmap.makeImage()
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WinPaint", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for old in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        where old.lastPathComponent.hasPrefix("Wallpaper-") {
            try? FileManager.default.removeItem(at: old)
        }
        let stamp = Int(Date().timeIntervalSince1970)
        do {
            for (i, screen) in NSScreen.screens.enumerated() {
                let url = folder.appendingPathComponent("Wallpaper-\(stamp)-\(i).png")
                var options: [NSWorkspace.DesktopImageOptionKey: Any] = [:]
                switch sender.tag {
                case 1:
                    let scale = screen.backingScaleFactor
                    let w = Int(screen.frame.width * scale), h = Int(screen.frame.height * scale)
                    let tiled = Bitmap(width: w, height: h, fill: nil)
                    for y in stride(from: 0, to: h, by: image.height) {
                        for x in stride(from: 0, to: w, by: image.width) {
                            tiled.draw(image, in: CGRect(x: x, y: y, width: image.width, height: image.height))
                        }
                    }
                    try ImageFile.write(tiled.makeImage(), to: url, format: .png, dpi: 72)
                    options = [.imageScaling: NSImageScaling.scaleAxesIndependently.rawValue, .allowClipping: true]
                case 2:
                    try ImageFile.write(image, to: url, format: .png, dpi: 72)
                    options = [.imageScaling: NSImageScaling.scaleNone.rawValue, .allowClipping: false, .fillColor: NSColor.black]
                default:
                    try ImageFile.write(image, to: url, format: .png, dpi: 72)
                    options = [.imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue, .allowClipping: true]
                }
                try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: options)
            }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @objc func imageProperties(_ sender: Any?) {
        guard let window else { return }
        canvas.commitAll()
        let sheet = ImagePropertiesSheet(size: canvas.bitmap.size, dpi: canvas.dpi, lastSaved: fileURL == nil ? nil : lastSaved,
                                         fileBytes: fileURL == nil ? nil : fileBytes)
        sheet.begin(on: window) { [weak self] ok in
            guard ok, let self else { return }
            let size = sheet.result
            if size != self.canvas.bitmap.size { self.canvas.resizeCanvas(width: Int(size.width), height: Int(size.height)) }
        }
    }

    @objc func openRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        openReplacing(url)
    }

    // MARK: Edit and Image menus

    @objc func pasteFrom(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url, let (image, _) = ImageFile.read(url) else { return }
        canvas.pasteImage(image)
    }

    @objc func invertSelection(_ sender: Any?) { canvas.invertSelection() }
    @objc func toggleTransparentSelection(_ sender: Any?) { canvas.transparentSelection.toggle() }
    @objc func rectangleSelection(_ sender: Any?) { canvas.selectionMode = .rectangle }
    @objc func freeFormSelection(_ sender: Any?) { canvas.selectionMode = .freeForm }
    @objc func crop(_ sender: Any?) { canvas.cropToSelection() }
    @objc func rotateRight(_ sender: Any?) { canvas.turn(.right) }
    @objc func rotateLeft(_ sender: Any?) { canvas.turn(.left) }
    @objc func rotate180(_ sender: Any?) { canvas.turn(.half) }
    @objc func flipVertical(_ sender: Any?) { canvas.turn(.flipVertical) }
    @objc func flipHorizontal(_ sender: Any?) { canvas.turn(.flipHorizontal) }
    @objc func invertColors(_ sender: Any?) { canvas.invertColors() }

    @objc func resizeAndSkew(_ sender: Any?) {
        guard let window else { return }
        canvas.commitText()
        canvas.commitShape()
        let sheet = ResizeSkewSheet(size: canvas.resizeTargetSize)
        sheet.begin(on: window) { [weak self] ok in
            guard ok, let self else { return }
            let r = sheet.result
            self.canvas.resizeAndSkew(width: r.width, height: r.height, skewH: r.skewH, skewV: r.skewV)
        }
    }

    func editColors() {
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.setTarget(nil)
        panel.color = canvas.editingColor2 ? canvas.color2 : canvas.color1
        panel.setTarget(self)
        panel.setAction(#selector(colorPanelChanged(_:)))
        colorSessionStarted = false
        panel.orderFront(nil)
    }

    @objc private func colorPanelChanged(_ sender: NSColorPanel) {
        let color = sender.color.usingColorSpace(.sRGB) ?? sender.color
        if canvas.editingColor2 { canvas.color2 = color } else { canvas.color1 = color }
        ribbon.addCustomColor(color, replacingNewest: colorSessionStarted)
        colorSessionStarted = true
    }

    // MARK: View menu

    @objc func zoomInImage(_ sender: Any?) { canvas.zoomIn() }
    @objc func zoomOutImage(_ sender: Any?) { canvas.zoomOut() }
    @objc func actualSize(_ sender: Any?) { canvas.setZoom(1) }
    @objc func fitToWindow(_ sender: Any?) { canvas.zoomToFit() }
    @objc func toggleRulers(_ sender: Any?) { scrollView.rulersVisible.toggle(); updateRulers() }
    @objc func toggleGridlines(_ sender: Any?) { canvas.showGrid.toggle() }
    @objc func toggleStatusBar(_ sender: Any?) { statusBar.isHidden.toggle() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleRulers(_:)): item.state = scrollView.rulersVisible ? .on : .off
        case #selector(toggleGridlines(_:)): item.state = canvas.showGrid ? .on : .off
        case #selector(toggleStatusBar(_:)): item.state = statusBar.isHidden ? .off : .on
        case #selector(toggleTransparentSelection(_:)): item.state = canvas.transparentSelection ? .on : .off
        case #selector(rectangleSelection(_:)): item.state = canvas.selectionMode == .rectangle ? .on : .off
        case #selector(freeFormSelection(_:)): item.state = canvas.selectionMode == .freeForm ? .on : .off
        case #selector(crop(_:)): return canvas.selection != nil
        case #selector(zoomInImage(_:)): return canvas.zoom < 8
        case #selector(zoomOutImage(_:)): return canvas.zoom > 0.125
        default: break
        }
        return true
    }

    // MARK: Window

    func windowShouldClose(_ sender: NSWindow) -> Bool { confirmDiscard() }

    func windowWillClose(_ notification: Notification) {
        if NSColorPanel.sharedColorPanelExists, NSColorPanel.shared.isVisible { NSColorPanel.shared.setTarget(nil) }
        AppDelegate.shared.windowClosed(self)
    }
}

/// The picture laid out on paper for printing.
private final class PrintImageView: NSView {
    let image: CGImage

    init(image: CGImage, size: NSSize) {
        self.image = image
        super.init(frame: NSRect(origin: .zero, size: size))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.cgContext.interpolationQuality = .high
        NSGraphicsContext.current?.cgContext.draw(image, in: bounds)
    }
}
