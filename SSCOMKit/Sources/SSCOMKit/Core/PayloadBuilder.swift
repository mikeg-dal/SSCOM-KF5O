public import Foundation

/// Text encodings offered for sending and displaying string data.
/// SSCOM on Windows always used the system ANSI code page (GBK on Chinese systems).
public enum TextEncodingOption: String, CaseIterable, Codable, Sendable, Identifiable {
    case utf8
    case gb18030
    case latin1

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .utf8: "UTF-8"
        case .gb18030: "GB18030 / GBK"
        case .latin1: "Latin-1"
        }
    }

    public var stringEncoding: String.Encoding {
        switch self {
        case .utf8: .utf8
        case .latin1: .isoLatin1
        case .gb18030:
            String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        }
    }
}

public enum PayloadError: Error, Equatable, Sendable, LocalizedError {
    case invalidHex(token: String)
    case invalidEscape(String)
    case unencodable

    public var errorDescription: String? {
        switch self {
        case .invalidHex(let token):
            "Not valid HEX data near “\(token)”. Use the characters 0-9, A-F and spaces, for example: FF 81 55 Aa"
        case .invalidEscape(let s):
            "Invalid escape sequence “\(s)”."
        case .unencodable:
            "The text contains characters that can't be represented in the selected encoding."
        }
    }
}

public enum HexCodec {
    /// Parses hex text such as "12 00 FF 80". Tokens are split on whitespace (and commas);
    /// a token of one or two digits is one byte, longer even-length tokens are read in pairs.
    public static func parse(_ text: String) throws(PayloadError) -> [UInt8] {
        var out: [UInt8] = []
        let tokens = text.split(whereSeparator: { $0.isWhitespace || $0 == "," })
        for token in tokens {
            var t = Substring(token)
            if t.hasPrefix("0x") || t.hasPrefix("0X") { t = t.dropFirst(2) }
            guard !t.isEmpty, t.allSatisfy(\.isHexDigit) else {
                throw .invalidHex(token: String(token))
            }
            if t.count <= 2 {
                out.append(UInt8(t, radix: 16)!)
            } else if t.count.isMultiple(of: 2) {
                var i = t.startIndex
                while i < t.endIndex {
                    let j = t.index(i, offsetBy: 2)
                    out.append(UInt8(t[i..<j], radix: 16)!)
                    i = j
                }
            } else {
                throw .invalidHex(token: String(token))
            }
        }
        return out
    }

    private static let digits = Array("0123456789ABCDEF".utf8)

    /// Formats bytes as SSCOM displays them: uppercase pairs each followed by a space.
    public static func format<C: Collection<UInt8>>(_ bytes: C, separator: String = " ") -> String {
        var s = String()
        s.reserveCapacity(bytes.count * 3)
        let sep = separator
        for b in bytes {
            s.unicodeScalars.append(UnicodeScalar(digits[Int(b >> 4)]))
            s.unicodeScalars.append(UnicodeScalar(digits[Int(b & 0xF)]))
            s += sep
        }
        return s
    }
}

public enum EscapeParser {
    /// Expands the escapes SSCOM supports in string mode:
    /// `\x??`, `\\`, `\r`, `\n`, `\t`, `\v`, `\a`, `\b`, `\f`, `\0`.
    /// Text between escapes is encoded with `encoding`; `\x??` inserts a raw byte.
    /// An unknown escape is sent literally, matching the original's lenient behaviour.
    public static func encode(_ text: String, encoding: String.Encoding) throws(PayloadError) -> [UInt8] {
        var out: [UInt8] = []
        var literal = ""
        func flush() throws(PayloadError) {
            guard !literal.isEmpty else { return }
            guard let data = literal.data(using: encoding, allowLossyConversion: false) else {
                throw .unencodable
            }
            out += data
            literal = ""
        }
        var it = text.makeIterator()
        while let c = it.next() {
            guard c == "\\" else { literal.append(c); continue }
            guard let e = it.next() else { literal.append("\\"); break }
            let simple: UInt8? = switch e {
            case "\\": 0x5C
            case "r": 0x0D
            case "n": 0x0A
            case "t": 0x09
            case "v": 0x0B
            case "a": 0x07
            case "b": 0x08
            case "f": 0x0C
            case "0": 0x00
            default: nil
            }
            if let simple {
                try flush()
                out.append(simple)
            } else if e == "x" || e == "X" {
                guard let h1 = it.next() else { throw .invalidEscape("\\x") }
                guard let h2 = it.next() else { throw .invalidEscape("\\x\(h1)") }
                guard let v = UInt8(String([h1, h2]), radix: 16) else {
                    throw .invalidEscape("\\x\(h1)\(h2)")
                }
                try flush()
                out.append(v)
            } else {
                literal.append("\\")
                literal.append(e)
            }
        }
        try flush()
        return out
    }
}

/// Everything that shapes an outgoing frame, shared by the main send box,
/// the preset strings and timed sending.
public struct SendOptions: Codable, Sendable, Equatable {
    public var hexMode: Bool
    public var appendCRLF: Bool
    public var interpretEscapes: Bool
    public var checksum: ChecksumKind
    public var placement: ChecksumPlacement
    public var encoding: TextEncodingOption

    public init(hexMode: Bool = false, appendCRLF: Bool = false, interpretEscapes: Bool = true,
                checksum: ChecksumKind = .none, placement: ChecksumPlacement = .init(),
                encoding: TextEncodingOption = .utf8) {
        self.hexMode = hexMode
        self.appendCRLF = appendCRLF
        self.interpretEscapes = interpretEscapes
        self.checksum = checksum
        self.placement = placement
        self.encoding = encoding
    }
}

public enum PayloadBuilder {
    /// Builds the bytes for one send. In string mode CR LF is appended before the
    /// checksum is calculated, so it is included in it (as SSCOM documents).
    public static func build(_ text: String, hex: Bool, options: SendOptions) throws(PayloadError) -> ChecksumResult {
        var bytes: [UInt8]
        if hex {
            bytes = try HexCodec.parse(text)
        } else {
            if options.interpretEscapes {
                bytes = try EscapeParser.encode(text, encoding: options.encoding.stringEncoding)
            } else {
                guard let d = text.data(using: options.encoding.stringEncoding, allowLossyConversion: false) else {
                    throw .unencodable
                }
                bytes = Array(d)
            }
            if options.appendCRLF { bytes += [0x0D, 0x0A] }
        }
        return options.checksum.apply(to: bytes, placement: options.placement)
    }
}
