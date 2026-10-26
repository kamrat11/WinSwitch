import AppKit
import Darwin

/// Copies or moves files in the background with a Windows-style progress window ("Copying 3 items from A to B",
/// percent, current file, Cancel). Large copies, like files pasted from a Remote Desktop session, no longer freeze
/// the Explorer window.
@MainActor
final class FileCopy {
    /// Files other apps keep in their own storage (Remote Desktop's clipboard folder, for example) are always copied:
    /// moving them would take them away from that app.
    static func isAppStorage(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return path.contains("/Library/Containers/") || path.contains("/Library/Group Containers/")
            || path.hasPrefix(NSTemporaryDirectory()) || path.hasPrefix("/private/var/folders/")
    }

    static func run(_ urls: [URL], to folder: URL, move: Bool, window: NSWindow?,
                    completion: @escaping ([URL], Error?) -> Void) {
        let move = move && !urls.contains(where: isAppStorage)
        let job = Job(urls: urls, folder: folder, move: move)
        let progress = ProgressWindow(job: job)
        // Only show the window for copies that take a moment.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            if !job.finished { progress.show(over: window) }
        }
        Thread.detachNewThread {
            job.perform()
            DispatchQueue.main.async {
                progress.close()
                if let error = job.error, isPermissionError(error), urls.contains(where: isAppStorage) {
                    explainAppStorage(window: window)
                    completion(job.results, nil)
                } else {
                    completion(job.results, job.cancelled ? nil : job.error)
                }
            }
        }
    }

    private static func isPermissionError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain { return ns.code == Int(EPERM) || ns.code == Int(EACCES) }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error { return isPermissionError(underlying) }
        return ns.domain == NSCocoaErrorDomain && [CocoaError.fileReadNoPermission.rawValue, CocoaError.fileWriteNoPermission.rawValue].contains(ns.code)
    }

    private static func explainAppStorage(window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = "macOS blocked reading the copied files"
        alert.informativeText = "Files copied in Remote Desktop (or another app) wait in that app's own storage, and macOS only lets WinSwitch read them with Full Disk Access.\n\nTurn on WinSwitch under Full Disk Access, then paste again."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { Explorer.requestFullDiskAccess() }
    }

    /// The copy itself, on a background thread; the progress window polls its counters.
    final class Job: @unchecked Sendable {
        let urls: [URL]
        let folder: URL
        let move: Bool
        private let lock = NSLock()
        private var _done: Int64 = 0
        private var _current = ""
        private var _cancelled = false
        private var _finished = false
        private(set) var total: Int64 = 0
        private(set) var results: [URL] = []
        private(set) var error: Error?
        private var fileBase: Int64 = 0

        init(urls: [URL], folder: URL, move: Bool) {
            self.urls = urls
            self.folder = folder
            self.move = move
        }

        var done: Int64 { lock.withLock { _done } }
        var current: String { lock.withLock { _current } }
        var cancelled: Bool { lock.withLock { _cancelled } }
        func cancel() { lock.withLock { _cancelled = true } }
        var finished: Bool { lock.withLock { _finished } }

        fileprivate func progressed(file: String?, copiedInFile: Int64?, fileFinished size: Int64?) {
            lock.withLock {
                if let file { _current = file }
                if let copiedInFile { _done = fileBase + copiedInFile }
                if let size { fileBase += size; _done = fileBase }
            }
        }

        func perform() {
            defer { lock.withLock { _finished = true } }
            let fm = FileManager.default
            if !move { total = urls.reduce(0) { $0 + Self.size(of: $1) } }
            for url in urls {
                if cancelled { break }
                // Pasting into the folder the file is already in makes a copy, like Windows.
                if move && url.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL { continue }
                let target = folder.standardizedFileURL.path
                if target.hasPrefix(url.standardizedFileURL.path + "/") || target == url.standardizedFileURL.path {
                    error = CocoaError(.fileWriteNoPermission, userInfo: [NSLocalizedDescriptionKey: "The destination folder is inside the source folder."])
                    break
                }
                let destination = FileOps.uniqueURL(for: url.lastPathComponent, in: folder, copySuffix: !move)
                do {
                    if move {
                        progressed(file: url.lastPathComponent, copiedInFile: nil, fileFinished: nil)
                        try fm.moveItem(at: url, to: destination)
                    } else {
                        try copy(url, to: destination)
                    }
                    results.append(destination)
                } catch {
                    if cancelled { try? fm.removeItem(at: destination) } else { self.error = error }
                    break
                }
            }
        }

        /// copyfile(3) copies folders recursively with their metadata and reports progress as it goes.
        private func copy(_ source: URL, to destination: URL) throws {
            let state = copyfile_state_alloc()
            defer { copyfile_state_free(state) }
            let context = Unmanaged.passUnretained(self).toOpaque()
            let callback: copyfile_callback_t = { what, stage, state, src, _, ctx in
                guard let ctx else { return COPYFILE_CONTINUE }
                let job = Unmanaged<Job>.fromOpaque(ctx).takeUnretainedValue()
                if job.cancelled { return COPYFILE_QUIT }
                let name = src.map { (String(cString: $0) as NSString).lastPathComponent }
                if what == COPYFILE_RECURSE_FILE && stage == COPYFILE_START {
                    job.progressed(file: name, copiedInFile: 0, fileFinished: nil)
                } else if what == COPYFILE_COPY_DATA && stage == COPYFILE_PROGRESS {
                    var copied: off_t = 0
                    copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied)
                    job.progressed(file: nil, copiedInFile: Int64(copied), fileFinished: nil)
                } else if what == COPYFILE_RECURSE_FILE && stage == COPYFILE_FINISH, let src {
                    var info = stat()
                    let size = stat(src, &info) == 0 ? Int64(info.st_size) : 0
                    job.progressed(file: nil, copiedInFile: nil, fileFinished: size)
                } else if stage == COPYFILE_ERR {
                    return COPYFILE_QUIT
                }
                return COPYFILE_CONTINUE
            }
            copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(callback, to: UnsafeRawPointer.self))
            copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), context)
            let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_NOFOLLOW_SRC | COPYFILE_EXCL)
            if copyfile(source.path, destination.path, state, flags) != 0 {
                let code = errno
                if cancelled { throw CocoaError(.userCancelled) }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [
                    NSLocalizedDescriptionKey: "Couldn't copy \"\(source.lastPathComponent)\": \(String(cString: strerror(code)))",
                    NSFilePathErrorKey: source.path])
            }
        }

        private static func size(of url: URL) -> Int64 {
            let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey]) else { return 0 }
            guard values.isDirectory == true else { return Int64(values.fileSize ?? 0) }
            var total: Int64 = 0
            let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [])
            while let item = walker?.nextObject() as? URL {
                if let v = try? item.resourceValues(forKeys: keys), v.isRegularFile == true { total += Int64(v.fileSize ?? 0) }
            }
            return total
        }
    }

    /// The progress window, updated a few times a second.
    @MainActor
    final class ProgressWindow: NSObject {
        private let job: Job
        private var panel: NSPanel?
        private var timer: Timer?
        private let title = NSTextField(labelWithString: "")
        private let percent = NSTextField(labelWithString: "")
        private let bar = NSProgressIndicator()
        private let detail = NSTextField(labelWithString: "")

        init(job: Job) { self.job = job }

        func show(over parent: NSWindow?) {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 150), styleMask: [.titled], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            let count = job.urls.count
            let from = job.urls.first?.deletingLastPathComponent().lastPathComponent ?? ""
            panel.title = job.move ? "Moving" : "Copying"
            title.stringValue = "\(job.move ? "Moving" : "Copying") \(count) item\(count == 1 ? "" : "s") from \(from) to \(job.folder.lastPathComponent)"
            title.lineBreakMode = .byTruncatingMiddle
            percent.font = .systemFont(ofSize: 15, weight: .semibold)
            bar.isIndeterminate = job.move || job.total == 0
            bar.minValue = 0
            bar.maxValue = 1
            bar.startAnimation(nil)
            detail.textColor = .secondaryLabelColor
            detail.lineBreakMode = .byTruncatingMiddle
            let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
            cancel.keyEquivalent = "\u{1b}"
            let buttons = NSStackView(views: [NSView(), cancel])
            let stack = NSStackView(views: [title, percent, bar, detail, buttons])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 8
            stack.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 14, right: 18)
            stack.translatesAutoresizingMaskIntoConstraints = false
            panel.contentView?.addSubview(stack)
            if let content = panel.contentView {
                NSLayoutConstraint.activate([
                    stack.leadingAnchor.constraint(equalTo: content.leadingAnchor), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                    stack.topAnchor.constraint(equalTo: content.topAnchor), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                    bar.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36),
                    buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36),
                    title.widthAnchor.constraint(lessThanOrEqualToConstant: 424), detail.widthAnchor.constraint(lessThanOrEqualToConstant: 424),
                ])
            }
            if let parent {
                panel.setFrameOrigin(NSPoint(x: parent.frame.midX - 230, y: parent.frame.midY - 75))
            } else {
                panel.center()
            }
            panel.orderFront(nil)
            self.panel = panel
            update()
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            }
        }

        private func update() {
            let done = job.done, total = job.total
            if total > 0 && !job.move {
                let fraction = min(1, Double(done) / Double(total))
                bar.doubleValue = fraction
                percent.stringValue = "\(Int(fraction * 100))% complete"
                let left = ByteCountFormatter.string(fromByteCount: max(0, total - done), countStyle: .file)
                detail.stringValue = "\(job.current)    (\(left) remaining)"
            } else {
                percent.stringValue = job.move ? "Moving..." : "Copying..."
                detail.stringValue = job.current
            }
        }

        @objc private func cancelClicked() {
            job.cancel()
            percent.stringValue = "Cancelling..."
        }

        func close() {
            timer?.invalidate()
            panel?.orderOut(nil)
            panel = nil
        }
    }
}
