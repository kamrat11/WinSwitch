import Foundation

/// Text encodings Notepad offers, with the names it shows in the status bar.
enum TextEncoding: String, CaseIterable, Codable {
    case utf8, utf8BOM, utf16LE, utf16BE, ansi

    var title: String {
        switch self {
        case .utf8: return "UTF-8"
        case .utf8BOM: return "UTF-8 with BOM"
        case .utf16LE: return "UTF-16 LE"
        case .utf16BE: return "UTF-16 BE"
        case .ansi: return "ANSI"
        }
    }

    private var bom: [UInt8] {
        switch self {
        case .utf8BOM: return [0xEF, 0xBB, 0xBF]
        case .utf16LE: return [0xFF, 0xFE]
        case .utf16BE: return [0xFE, 0xFF]
        case .utf8, .ansi: return []
        }
    }

    private var foundation: String.Encoding {
        switch self {
        case .utf8, .utf8BOM: return .utf8
        case .utf16LE: return .utf16LittleEndian
        case .utf16BE: return .utf16BigEndian
        case .ansi: return .windowsCP1252
        }
    }

    /// Detects the encoding from a BOM, then valid UTF-8, else Windows-1252 (ANSI), and decodes the text.
    static func decode(_ data: Data) -> (String, TextEncoding) {
        let bytes = [UInt8](data.prefix(3))
        for encoding in [TextEncoding.utf8BOM, .utf16LE, .utf16BE] where bytes.starts(with: encoding.bom) {
            if let text = String(data: data.dropFirst(encoding.bom.count), encoding: encoding.foundation) {
                return (text, encoding)
            }
        }
        if let text = String(data: data, encoding: .utf8) { return (text, .utf8) }
        return (String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self), .ansi)
    }

    /// True when the text can be written in this encoding without losing characters.
    func canEncode(_ text: String) -> Bool { text.data(using: foundation, allowLossyConversion: false) != nil }

    func encode(_ text: String) -> Data {
        var data = Data(bom)
        data.append(text.data(using: foundation, allowLossyConversion: true) ?? Data())
        return data
    }
}

enum LineEnding: String, CaseIterable, Codable {
    case crlf, lf, cr

    var title: String {
        switch self {
        case .crlf: return "Windows (CRLF)"
        case .lf: return "Unix (LF)"
        case .cr: return "Macintosh (CR)"
        }
    }

    var characters: String {
        switch self {
        case .crlf: return "\r\n"
        case .lf: return "\n"
        case .cr: return "\r"
        }
    }

    /// The first line ending in the text; Windows (CRLF) when there is none.
    static func detect(in text: String) -> LineEnding {
        let ns = text as NSString
        let r = ns.rangeOfCharacter(from: CharacterSet(charactersIn: "\r\n"))
        guard r.location != NSNotFound else { return .crlf }
        if ns.character(at: r.location) == 10 { return .lf }
        return r.location + 1 < ns.length && ns.character(at: r.location + 1) == 10 ? .crlf : .cr
    }
}

/// Reading and writing text files the way Notepad does: the editor works with "\n" only, and the file keeps its
/// encoding and line ending.
enum TextFile {
    struct Contents {
        var text: String
        var encoding: TextEncoding
        var lineEnding: LineEnding
    }

    static func read(_ url: URL) throws -> Contents {
        let (raw, encoding) = TextEncoding.decode(try Data(contentsOf: url))
        return Contents(text: normalize(raw), encoding: encoding, lineEnding: LineEnding.detect(in: raw))
    }

    static func normalize(_ text: String) -> String {
        (text as NSString).replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    static func data(for text: String, encoding: TextEncoding, lineEnding: LineEnding) -> Data {
        let out = lineEnding == .lf ? text : (text as NSString).replacingOccurrences(of: "\n", with: lineEnding.characters)
        return encoding.encode(out)
    }

    /// Notepad's time/date stamp, e.g. "10:04 AM 10/28/2026".
    static func timeDate(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "h:mm a M/d/yyyy"
        return formatter.string(from: date)
    }
}
