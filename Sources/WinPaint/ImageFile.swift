import AppKit
import CoreImage
import UniformTypeIdentifiers

/// The picture formats of Save as.
enum ImageFormat: Int, CaseIterable {
    case png, jpeg, bmp, gif, tiff, heic

    var title: String {
        switch self {
        case .png: return "PNG (*.png)"
        case .jpeg: return "JPEG (*.jpg;*.jpeg;*.jpe;*.jfif)"
        case .bmp: return "Monochrome / 24-bit Bitmap (*.bmp;*.dib)"
        case .gif: return "GIF (*.gif)"
        case .tiff: return "TIFF (*.tif;*.tiff)"
        case .heic: return "HEIC (*.heic)"
        }
    }

    var menuTitle: String {
        switch self {
        case .png: return "PNG picture"
        case .jpeg: return "JPEG picture"
        case .bmp: return "BMP picture"
        case .gif: return "GIF picture"
        case .tiff: return "TIFF picture"
        case .heic: return "HEIC picture"
        }
    }

    var type: UTType {
        switch self {
        case .png: return .png
        case .jpeg: return .jpeg
        case .bmp: return .bmp
        case .gif: return .gif
        case .tiff: return .tiff
        case .heic: return .heic
        }
    }

    var fileExtension: String { type.preferredFilenameExtension ?? "png" }

    /// Formats without an alpha channel get a white background.
    var isOpaque: Bool { self == .jpeg || self == .bmp }

    static func forURL(_ url: URL) -> ImageFormat? {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return nil }
        return allCases.first { type.conforms(to: $0.type) }
    }
}

enum ImageFile {
    /// Reads the first picture of a file (the largest one of an icon), with its resolution.
    static func read(_ url: URL) -> (image: CGImage, dpi: CGFloat)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }
        var best = 0, bestWidth = 0
        if count > 1, (CGImageSourceGetType(source) as String?) == UTType.ico.identifier {
            for i in 0..<count {
                let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any]
                let w = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
                if w > bestWidth { bestWidth = w; best = i }
            }
        }
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        guard let image = CGImageSourceCreateImageAtIndex(source, best, options) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, best, nil) as? [CFString: Any]
        let dpi = (props?[kCGImagePropertyDPIWidth] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 96
        return (applyOrientation(image, props), dpi > 0 ? dpi : 96)
    }

    /// Turns camera pictures upright using their EXIF orientation.
    private static func applyOrientation(_ image: CGImage, _ props: [CFString: Any]?) -> CGImage {
        guard let raw = props?[kCGImagePropertyOrientation] as? UInt32, raw > 1,
              let orientation = CGImagePropertyOrientation(rawValue: raw) else { return image }
        let ci = CIImage(cgImage: image).oriented(orientation)
        return CIContext().createCGImage(ci, from: ci.extent) ?? image
    }

    static func write(_ image: CGImage, to url: URL, format: ImageFormat, dpi: CGFloat) throws {
        var output = image
        if format.isOpaque {
            let flat = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                 space: sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            flat.setFillColor(NSColor.white.cgColor)
            flat.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            flat.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            output = flat.makeImage()!
        }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, format.type.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        var props: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
        if format == .jpeg || format == .heic { props[kCGImageDestinationLossyCompressionQuality] = 0.9 }
        CGImageDestinationAddImage(destination, output, props as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    static func sizeText(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) bytes" }
        let kb = Double(bytes) / 1024
        if kb < 1024 { return String(format: "%.1fKB", kb) }
        return String(format: "%.1fMB", kb / 1024)
    }
}
