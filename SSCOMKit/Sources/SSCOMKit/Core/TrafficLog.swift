public import Foundation

public enum Direction: Sendable, Equatable, Codable {
    case received
    case sent
}

/// One packet of traffic. Received bytes that arrive within the packet timeout
/// of each other are merged into the same segment, which is how SSCOM's
/// "show time and packet" display decides where a packet starts.
public struct TrafficSegment: Sendable, Equatable {
    public var direction: Direction
    public var timestamp: Date
    public var lastActivity: Date
    public var bytes: [UInt8]
}

public struct DisplayOptions: Sendable, Equatable {
    public var hex: Bool
    public var timestamps: Bool
    public var encoding: TextEncodingOption
    public var chinese: Bool

    public init(hex: Bool = false, timestamps: Bool = true, encoding: TextEncodingOption = .utf8, chinese: Bool = false) {
        self.hex = hex
        self.timestamps = timestamps
        self.encoding = encoding
        self.chinese = chinese
    }
}

/// The full traffic history behind the receive window, plus a renderer.
///
/// Unlike SSCOM, which lost its timestamps when switching to HEX display,
/// keeping segments lets the window be re-rendered in any mode at any time.
public struct TrafficLog: Sendable {
    public private(set) var segments: [TrafficSegment] = []
    public private(set) var byteCount = 0
    /// Bytes kept when the display limit is exceeded (SSCOM keeps the newest 100 KB).
    public var retainAfterTrim = 100_000
    public var limit: Int

    public init(limit: Int = 1_000_000) {
        self.limit = limit
    }

    public enum AppendResult: Sendable, Equatable {
        /// A new segment was started; its index is returned.
        case newSegment(Int)
        /// Bytes were added to the last segment.
        case extended
        /// Old data was dropped; the whole display must be rebuilt.
        case trimmed
    }

    /// Adds traffic. Received bytes join the previous received segment when they
    /// arrive within `packetTimeout` of it; sent data always starts a new segment.
    @discardableResult
    public mutating func append(_ bytes: [UInt8], direction: Direction, at date: Date, packetTimeout: TimeInterval) -> AppendResult {
        guard !bytes.isEmpty else { return .extended }
        byteCount += bytes.count
        var result: AppendResult
        if direction == .received, var last = segments.last, last.direction == .received,
           date.timeIntervalSince(last.lastActivity) <= packetTimeout {
            last.bytes += bytes
            last.lastActivity = date
            segments[segments.count - 1] = last
            result = .extended
        } else {
            segments.append(TrafficSegment(direction: direction, timestamp: date, lastActivity: date, bytes: bytes))
            result = .newSegment(segments.count - 1)
        }
        if byteCount > limit {
            trim()
            result = .trimmed
        }
        return result
    }

    public mutating func removeAll() {
        segments.removeAll()
        byteCount = 0
    }

    private mutating func trim() {
        var kept = 0
        var firstKept = segments.count
        while firstKept > 0, kept + segments[firstKept - 1].bytes.count <= retainAfterTrim {
            firstKept -= 1
            kept += segments[firstKept].bytes.count
        }
        if firstKept > 0, kept < retainAfterTrim {
            // Keep the tail of the segment that straddles the boundary.
            var partial = segments[firstKept - 1]
            partial.bytes = Array(partial.bytes.suffix(retainAfterTrim - kept))
            kept += partial.bytes.count
            segments.removeFirst(firstKept - 1)
            segments[0] = partial
        } else {
            segments.removeFirst(firstKept)
        }
        byteCount = kept
    }

    /// Raw received bytes, oldest first (used for "save raw data" and the waveform).
    public var receivedBytes: [UInt8] {
        segments.lazy.filter { $0.direction == .received }.flatMap(\.bytes)
    }
}

/// Converts traffic into display text.
public struct TrafficRenderer: Sendable {
    public var options: DisplayOptions
    private var decoder: StreamingTextDecoder
    /// True when the last text produced ended a line, so a header needs no extra newline.
    public var atLineStart = true

    public init(options: DisplayOptions) {
        self.options = options
        self.decoder = StreamingTextDecoder(encoding: options.encoding)
    }

    /// 24-hour "HH:mm:ss.SSS" in the local time zone, as SSCOM prints it.
    public static func timestamp(_ date: Date, timeZone: TimeZone = .current) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
        let ms = min((c.nanosecond ?? 0) / 1_000_000, 999)
        return String(format: "%02d:%02d:%02d.%03d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0, ms)
    }

    /// Header written before a segment, e.g. "\n[09:30:38.094] TX ". Windows SSCOM used "发→◇" and
    /// "收←◆"; those symbols aren't in macOS's monospaced fonts and render from a fallback font,
    /// so plain letters are used instead.
    public func header(for segment: TrafficSegment, isFirst: Bool) -> String {
        guard options.timestamps else { return "" }
        let arrow = switch (segment.direction, options.chinese) {
        case (.sent, true): "发 "
        case (.sent, false): "TX "
        case (.received, true): "收 "
        case (.received, false): "RX "
        }
        return (isFirst || atLineStart ? "" : "\n") + "[\(Self.timestamp(segment.timestamp))] " + arrow
    }

    /// Footer written after a sent segment. Windows SSCOM ended sent packets with "□", which on macOS
    /// looks like a character that failed to render, so nothing is written.
    public func footer(for segment: TrafficSegment) -> String { "" }

    /// Shows control bytes as "<01>" so they're visible in text mode. (Unicode control pictures such as
    /// ␁ aren't in macOS's monospaced fonts.) Tab, line feed and carriage return keep their normal effect.
    public static func visibleControls(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { ($0.value < 0x20 && !"\t\n\r".unicodeScalars.contains($0)) || $0.value == 0x7F }) else {
            return text
        }
        var out = ""
        for s in text.unicodeScalars {
            switch s.value {
            case 0x09, 0x0A, 0x0D: out.unicodeScalars.append(s)
            case 0x00..<0x20, 0x7F: out += String(format: "<%02X>", s.value)
            default: out.unicodeScalars.append(s)
            }
        }
        return out
    }

    /// Renders new bytes of a received segment (or a whole sent segment).
    public mutating func body(_ bytes: [UInt8], direction: Direction) -> String {
        let text: String
        if options.hex {
            text = HexCodec.format(bytes)
        } else if direction == .sent {
            // Sent packets are rendered whole, independent of the receive stream.
            var d = StreamingTextDecoder(encoding: options.encoding)
            text = Self.visibleControls(d.decode(bytes) + d.flush())
        } else {
            text = Self.visibleControls(decoder.decode(bytes))
        }
        note(text)
        return text
    }

    /// Call when a received segment ends so a dangling partial character is shown.
    public mutating func endReceivedSegment() -> String {
        let text = options.hex ? "" : Self.visibleControls(decoder.flush())
        note(text)
        return text
    }

    /// Records whether emitted text left the cursor at the start of a line.
    public mutating func note(_ text: String) {
        if let last = text.last { atLineStart = last.isNewline }
    }

    /// Renders an entire log from scratch.
    public mutating func render(_ log: TrafficLog) -> String {
        decoder = StreamingTextDecoder(encoding: options.encoding)
        atLineStart = true
        var out = ""
        var previous: Direction?
        for (i, seg) in log.segments.enumerated() {
            if previous == .received { out += endReceivedSegment() }
            if !options.timestamps, seg.direction == .sent { previous = .sent; continue }
            let h = header(for: seg, isFirst: i == 0)
            note(h)
            out += h
            out += body(seg.bytes, direction: seg.direction)
            let f = footer(for: seg)
            note(f)
            out += f
            previous = seg.direction
        }
        return out
    }
}

/// Decodes a byte stream to text without splitting multi-byte characters
/// that arrive in separate reads. Undecodable bytes become U+FFFD.
public struct StreamingTextDecoder: Sendable {
    public let encoding: TextEncodingOption
    private var pending: [UInt8] = []

    public init(encoding: TextEncodingOption) {
        self.encoding = encoding
    }

    public mutating func decode(_ bytes: [UInt8]) -> String {
        pending += bytes
        let cut = completePrefixLength(pending)
        guard cut > 0 else { return "" }
        let chunk = Array(pending[..<cut])
        pending.removeFirst(cut)
        return Self.decodeLossy(chunk, encoding: encoding)
    }

    public mutating func flush() -> String {
        defer { pending.removeAll() }
        return pending.isEmpty ? "" : Self.decodeLossy(pending, encoding: encoding)
    }

    /// Length of the longest prefix that doesn't end inside a multi-byte sequence.
    private func completePrefixLength(_ b: [UInt8]) -> Int {
        switch encoding {
        case .latin1:
            return b.count
        case .utf8:
            // Look back at most 3 bytes for an unfinished lead byte.
            var i = b.count - 1
            var back = 0
            while i >= 0, back < 4 {
                let c = b[i]
                if c & 0xC0 != 0x80 {
                    let need = c >= 0xF0 ? 4 : c >= 0xE0 ? 3 : c >= 0xC0 ? 2 : 1
                    return (b.count - i) < need ? i : b.count
                }
                i -= 1; back += 1
            }
            return b.count
        case .gb18030:
            var i = 0
            while i < b.count {
                let c = b[i]
                if c < 0x81 || c == 0xFF { i += 1; continue }
                guard i + 1 < b.count else { return i }
                let c2 = b[i + 1]
                if (0x30...0x39).contains(c2) {
                    guard i + 3 < b.count else { return i }
                    i += 4
                } else {
                    i += 2
                }
            }
            return b.count
        }
    }

    static func decodeLossy(_ bytes: [UInt8], encoding: TextEncodingOption) -> String {
        switch encoding {
        case .utf8:
            return String(decoding: bytes, as: UTF8.self)
        case .latin1:
            return String(bytes.map { Character(UnicodeScalar($0)) })
        case .gb18030:
            if let s = String(bytes: bytes, encoding: encoding.stringEncoding) { return s }
            // Fall back character by character so one bad byte doesn't lose the rest.
            var out = ""
            var i = 0
            while i < bytes.count {
                let c = bytes[i]
                if c < 0x80 { out.unicodeScalars.append(UnicodeScalar(c)); i += 1; continue }
                let len = (i + 1 < bytes.count && (0x30...0x39).contains(bytes[i + 1])) ? 4 : 2
                let end = min(i + len, bytes.count)
                if let s = String(bytes: bytes[i..<end], encoding: encoding.stringEncoding) {
                    out += s; i = end
                } else {
                    out += "\u{FFFD}"; i += 1
                }
            }
            return out
        }
    }
}
