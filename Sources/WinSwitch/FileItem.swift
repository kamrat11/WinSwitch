import AppKit
import UniformTypeIdentifiers

/// One row in the Explorer list.
struct FileItem {
    let url: URL
    let name: String
    let isDirectory: Bool
    let isPackage: Bool
    let isHidden: Bool
    let modified: Date?
    let size: Int64?
    let typeDescription: String

    /// Folders open in Explorer; packages (.app etc.) open like files.
    var opensAsFolder: Bool { isDirectory && !isPackage }

    private static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isPackageKey, .isHiddenKey, .contentModificationDateKey, .fileSizeKey,
        .localizedTypeDescriptionKey, .localizedNameKey,
    ]
    static var resourceKeys: [URLResourceKey] { keys }

    init?(url: URL) {
        guard let values = try? url.resourceValues(forKeys: Set(Self.keys)) else { return nil }
        self.url = url
        name = url.lastPathComponent
        isDirectory = values.isDirectory ?? false
        isPackage = values.isPackage ?? false
        isHidden = values.isHidden ?? url.lastPathComponent.hasPrefix(".")
        modified = values.contentModificationDate
        size = isDirectory ? nil : values.fileSize.map(Int64.init)
        typeDescription = values.localizedTypeDescription ?? (isDirectory ? "Folder" : "File")
    }

    static func contents(of folder: URL, showHidden: Bool) -> [FileItem] {
        let options: FileManager.DirectoryEnumerationOptions = showHidden ? [] : [.skipsHiddenFiles]
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: options)) ?? []
        return urls.compactMap(FileItem.init(url:))
    }

    // MARK: Formatting

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    var dateText: String { modified.map(Self.dateFormatter.string(from:)) ?? "" }

    /// Windows shows sizes in KB.
    var sizeText: String {
        guard let size else { return "" }
        let kb = max(1, (size + 1023) / 1024)
        return NumberFormatter.localizedString(from: NSNumber(value: kb), number: .decimal) + " KB"
    }
}

/// Copy, move, rename and delete with Windows-style names for conflicts ("name - Copy.txt").
enum FileOps {
    static func uniqueURL(for name: String, in folder: URL, copySuffix: Bool) -> URL {
        let fm = FileManager.default
        let candidate = folder.appendingPathComponent(name)
        if !fm.fileExists(atPath: candidate.path) { return candidate }
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        func make(_ stem: String) -> URL {
            folder.appendingPathComponent(ext.isEmpty ? stem : "\(stem).\(ext)")
        }
        let first = copySuffix ? "\(base) - Copy" : "\(base) (2)"
        if !fm.fileExists(atPath: make(first).path) { return make(first) }
        var n = 2
        while true {
            let stem = copySuffix ? "\(base) - Copy (\(n))" : "\(base) (\(n + 1))"
            if !fm.fileExists(atPath: make(stem).path) { return make(stem) }
            n += 1
        }
    }

    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let va = try? a.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject
        let vb = try? b.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject
        return va != nil && va == vb
    }
}
