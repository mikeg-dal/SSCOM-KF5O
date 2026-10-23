public import Foundation

/// One of SSCOM's 99 user-defined send strings ("多条字符串").
public struct PresetString: Codable, Sendable, Equatable, Identifiable {
    public var id: Int
    public var hex: Bool
    public var text: String
    /// Shown on the send button; double-click the text field to edit it.
    public var note: String
    /// Loop-send order; 0 means "never sent by the loop".
    public var order: Int
    /// Delay after sending this entry while looping, in milliseconds.
    public var delayMs: Int

    public init(id: Int, hex: Bool = false, text: String = "", note: String = "", order: Int = 0, delayMs: Int = 1000) {
        self.id = id
        self.hex = hex
        self.text = text
        self.note = note
        self.order = order
        self.delayMs = delayMs
    }

    public static let count = 99

    public static func defaults() -> [PresetString] {
        var list = (1...count).map { PresetString(id: $0) }
        list[0] = PresetString(id: 1, hex: true, text: "13 00 FF 88", note: "HEX string 1", order: 1)
        list[1] = PresetString(id: 2, text: "output string", note: "String 1", order: 3)
        list[2] = PresetString(id: 3, text: "Welcome to SSCOM!", note: "Greeting", order: 2)
        return list
    }

    /// Entries the loop sends, in order: ascending order number, ties in list order.
    public static func loopSequence(_ presets: [PresetString]) -> [PresetString] {
        presets.enumerated()
            .filter { $0.element.order > 0 && !$0.element.text.isEmpty }
            .sorted { ($0.element.order, $0.offset) < ($1.element.order, $1.offset) }
            .map(\.element)
    }
}

/// Settings recovered from an SSCOM `sscom51.ini` file.
public struct LegacyIniSettings: Sendable, Equatable {
    public var presets: [PresetString] = []
    public var values: [Int: String] = [:]

    public var baudRate: Int? { values[1081].flatMap { Int($0) } }
    public var mainText: String? { values[1053] }
    public var mainHexText: String? { values[1054] }
    public var mainHexMode: Bool? { values[1055].map { $0 == "H" } }
    public var timedSendInterval: Int? { values[1056].flatMap { Int($0) } }
    public var appendCRLF: Bool? { values[1057].map { $0 == "Y" } }
    public var presetLoopDelay: Int? { values[1058].flatMap { Int($0) } }
    public var hexDisplay: Bool? { values[1059].map { $0 == "Y" } }
    public var dtr: Bool? { values[1061].map { $0 == "Y" } }
    public var rts: Bool? { values[1062].map { $0 == "Y" } }
    public var openAtStartup: Bool? { values[1063].map { $0 == "Y" } }
    public var timestamps: Bool? { values[1064].map { $0 == "Y" } }
    public var packetTimeoutMs: Int? { values[1065].flatMap { Int($0) } }
    public var remoteIP: String? { values[1068] }
    public var remotePort: Int? { values[1069].flatMap { Int($0) } }
    public var localPort: Int? { values[1070].flatMap { Int($0) } }
    public var checksumFirstByte: Int? { values[1074].flatMap { Int($0) } }
    /// N1060, the checksum combo box index.
    public var checksumKind: ChecksumKind? { values[1060].flatMap { Int($0) }.flatMap(ChecksumKind.init(rawValue:)) }

    /// The checksum to use with these strings. Waveshare's "modbus tcp.ini" sets ModbusCRC16 although
    /// Modbus TCP frames carry no CRC (its wiki says to choose None), so a file whose HEX strings all
    /// start with a Modbus TCP header gets None.
    public var effectiveChecksumKind: ChecksumKind? {
        guard let kind = checksumKind else { return nil }
        let hex = presets.filter { $0.hex && !$0.text.isEmpty }
        let tcp = !hex.isEmpty && hex.allSatisfy { $0.text.replacingOccurrences(of: " ", with: "").hasPrefix("0000000000") }
        return tcp && kind == .modbusCRC16 ? ChecksumKind.none : kind
    }
}

/// A ready-made set of send strings, like the ini files device makers ship with SSCOM.
public struct PresetSet: Sendable, Identifiable {
    public var id: String
    public var name: String
    public var summary: String
    /// The checksum the strings need (they're stored without it, as in the original ini files).
    public var checksum: ChecksumKind
    /// The device's TCP port for these commands.
    public var port: Int
    public var presets: [PresetString]
}

public enum PresetLibrary {
    public static let all: [PresetSet] = [relayRTU, relayTCP]

    /// Waveshare "Modbus POE ETH Relay (B)": slot, note, Modbus PDU (unit ID first, no CRC).
    /// Same slots and commands as Waveshare's modbus rtu.ini / modbus tcp.ini, with English notes.
    /// Relay numbers are the board's 1–8 (coil addresses 0–7).
    static let relayCommands: [(Int, String, String)] = {
        var list: [(Int, String, String)] = []
        for ch in 0..<8 {
            list.append((ch * 2 + 1, "Relay \(ch + 1) on", String(format: "01 05 00 %02X FF 00", ch)))
            list.append((ch * 2 + 2, "Relay \(ch + 1) off", String(format: "01 05 00 %02X 00 00", ch)))
        }
        for ch in 0..<4 {
            list.append((18 + ch, "Relay \(ch + 1) toggle", String(format: "01 05 00 %02X 55 00", ch)))
        }
        list += [
            (23, "All relays on", "01 05 00 FF FF 00"),
            (24, "All relays off", "01 05 00 FF 00 00"),
            (25, "All relays toggle", "01 05 00 FF 55 00"),
            (27, "Write all on", "01 0F 00 00 00 08 01 FF"),
            (28, "Write all off", "01 0F 00 00 00 08 01 00"),
            (29, "5–6 on, 7–8 off", "01 0F 00 04 00 04 01 03"),
            (31, "Relay 1 flash on 700 ms", "01 05 02 00 00 07"),
            (32, "Relay 2 flash on 800 ms", "01 05 02 01 00 08"),
            (33, "Relay 1 flash off 500 ms", "01 05 04 00 00 05"),
            (34, "Relay 2 flash off 600 ms", "01 05 04 01 00 06"),
            (36, "Read relay states", "01 01 00 00 00 08"),
            (37, "Read inputs", "01 02 00 00 00 08"),
            (39, "Read control modes", "01 03 10 00 00 08"),
            (40, "Relay 1 linkage mode", "01 06 10 00 00 01"),
            (41, "All linkage mode", "01 10 10 00 00 08 10 00 01 00 01 00 01 00 01 00 01 00 01 00 01 00 01"),
            (42, "All normal mode", "01 10 10 00 00 08 10 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00"),
            (44, "Read device address", "00 03 40 00 00 01"),
            (45, "Read software version", "00 03 80 00 00 01"),
        ]
        return list
    }()

    static func relaySet(tcp: Bool) -> [PresetString] {
        var list = (1...PresetString.count).map { PresetString(id: $0) }
        for (slot, note, pdu) in relayCommands {
            var text = pdu
            if tcp {
                // Modbus TCP header: transaction 0, protocol 0, then the length of what follows.
                let length = pdu.split(separator: " ").count
                text = String(format: "00 00 00 00 00 %02X ", length) + pdu
            }
            list[slot - 1] = PresetString(id: slot, hex: true, text: text, note: note)
        }
        return list
    }

    public static let relayRTU = PresetSet(
        id: "waveshare-relay-rtu",
        name: "Modbus POE ETH Relay (B) — Modbus RTU",
        summary: "For the relay's default Transfer Protocol \"None\". ModbusCRC16 is added to every command.",
        checksum: .modbusCRC16,
        port: 4196,
        presets: relaySet(tcp: false))

    public static let relayTCP = PresetSet(
        id: "waveshare-relay-tcp",
        name: "Modbus POE ETH Relay (B) — Modbus TCP",
        summary: "For Transfer Protocol \"Modbus TCP\" (port 502). No checksum is added.",
        checksum: .none,
        port: 502,
        presets: relaySet(tcp: true))
}

public enum LegacyIniImporter {
    /// Reads an SSCOM ini file. They are written in the Windows ANSI code page,
    /// so GB18030 is tried first, then UTF-8.
    public static func load(_ data: Data) -> LegacyIniSettings {
        let text = String(data: data, encoding: TextEncodingOption.gb18030.stringEncoding)
            ?? String(decoding: data, as: UTF8.self)
        return parse(text)
    }

    public static func parse(_ text: String) -> LegacyIniSettings {
        var headers: [Int: (order: Int, note: String, delay: Int)] = [:]
        var bodies: [Int: (hex: Bool, text: String)] = [:]
        var result = LegacyIniSettings()
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            guard line.hasPrefix("N"), let eq = line.firstIndex(of: "=") else { continue }
            guard let key = Int(line[line.index(after: line.startIndex)..<eq]) else { continue }
            let value = String(line[line.index(after: eq)...])
            switch key {
            case 101...199:
                // "order,note,delay" — the note may itself contain commas.
                var parts = value.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
                guard parts.count >= 3, let order = Int(parts.removeFirst()), let delay = Int(parts.removeLast()) else { continue }
                headers[key - 100] = (order, parts.joined(separator: ","), delay)
            case 1...99:
                // "H,13 00 FF 88" or "A,text"
                guard let comma = value.firstIndex(of: ",") else { continue }
                bodies[key] = (value[..<comma] == "H", String(value[value.index(after: comma)...]))
            case 1000...:
                // "N1081=,115200"
                result.values[key] = value.hasPrefix(",") ? String(value.dropFirst()) : value
            default:
                break
            }
        }
        if !bodies.isEmpty || !headers.isEmpty {
            result.presets = (1...PresetString.count).map { i in
                let h = headers[i]
                let b = bodies[i]
                return PresetString(id: i, hex: b?.hex ?? false, text: b?.text ?? "",
                                    note: h?.note ?? "", order: h?.order ?? 0, delayMs: h?.delay ?? 1000)
            }
        }
        return result
    }
}
