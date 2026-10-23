import AppKit
import SSCOMKit

enum LinkMode: String, Codable, CaseIterable, Identifiable {
    case serial, tcpClient, tcpServer, udp
    var id: String { rawValue }
    var title: String {
        switch self {
        case .serial: String(localized: "Serial Port")
        case .tcpClient: "TCP Client"
        case .tcpServer: "TCP Server"
        case .udp: "UDP"
        }
    }
}

enum FileSendDelay: Int, Codable, CaseIterable, Identifiable {
    case none = 0, ms1 = 1, ms10 = 10, ms50 = 50, ms100 = 100
    var id: Int { rawValue }
    var title: String {
        self == .none ? String(localized: "Continuous") : String(localized: "Delay \(rawValue) ms every 256 bytes")
    }
}

enum TerminalInputMode: String, Codable, CaseIterable, Identifiable {
    /// Send each key as it is pressed (SSCOM default).
    case keystroke
    /// Echo typing locally and send the line when Return is pressed.
    case line
    var id: String { rawValue }
}

enum MarkerLanguage: String, Codable, CaseIterable, Identifiable {
    case automatic, english, chinese
    var id: String { rawValue }
}

/// A Codable RGBA color for persisting the receive window's colors.
struct StoredColor: Codable, Equatable {
    var r, g, b, a: Double
    init(_ c: NSColor) {
        let s = c.usingColorSpace(.sRGB) ?? .black
        (r, g, b, a) = (s.redComponent, s.greenComponent, s.blueComponent, s.alphaComponent)
    }
    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
}

/// Everything SSCOM saved in sscom51.ini, as one Codable value stored in UserDefaults.
struct AppSettings: Codable, Equatable {
    // Link
    var mode: LinkMode = .serial
    var portPath: String?
    var serial = SerialSettings()
    var remoteHost = "127.0.0.1"
    var remotePort = 8080
    var localHost = "0.0.0.0"
    var localPort = 8080
    var openAtStartup = false
    var autoReconnect = true

    // Sending
    var sendText = "abcdefg"
    var sendHexText = "12 FF 00 30"
    var send = SendOptions()
    var timedSendInterval = 1000
    var fileSendDelay: FileSendDelay = .ms1

    // Receiving / display
    var hexDisplay = false
    var timestamps = true
    var packetTimeoutMs = 20
    var displayLimit = 1_000_000
    var markerLanguage: MarkerLanguage = .automatic
    var fontName = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular).fontName
    var fontSize: Double = 12
    var textColor = StoredColor(.textColor)
    var backgroundColor = StoredColor(.textBackgroundColor)
    var alwaysOnTop = false

    // Terminal emulation
    var terminalInput: TerminalInputMode = .keystroke
    var terminalLocalEcho = false
    var terminalCRLF = false

    // Preset strings
    var presets = PresetString.defaults()
    var presetsVisible = false

    // ISP
    var stm32Speed: STM32Flasher.Speed = .fast
    var stm32Reset = ResetControl()
    var stcSpeed: STCFlasher.Speed = .normal

    static let displayLimits = [200_000, 500_000, 1_000_000, 2_000_000, 5_000_000]

    var useChineseMarkers: Bool {
        switch markerLanguage {
        case .chinese: true
        case .english: false
        case .automatic: Locale.preferredLanguages.first?.hasPrefix("zh") ?? false
        }
    }

    var displayOptions: DisplayOptions {
        DisplayOptions(hex: hexDisplay, timestamps: timestamps, encoding: send.encoding, chinese: useChineseMarkers)
    }

    // Tolerate settings saved by older builds that lack newer keys.
    init() {}
    init(from decoder: any Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func load<T: Decodable>(_ key: CodingKeys, _ target: inout T) {
            if let v = try? c.decode(T.self, forKey: key) { target = v }
        }
        load(.mode, &mode); load(.portPath, &portPath); load(.serial, &serial)
        load(.remoteHost, &remoteHost); load(.remotePort, &remotePort); load(.localHost, &localHost)
        load(.localPort, &localPort); load(.openAtStartup, &openAtStartup); load(.autoReconnect, &autoReconnect)
        load(.sendText, &sendText); load(.sendHexText, &sendHexText); load(.send, &send)
        load(.timedSendInterval, &timedSendInterval); load(.fileSendDelay, &fileSendDelay)
        load(.hexDisplay, &hexDisplay); load(.timestamps, &timestamps); load(.packetTimeoutMs, &packetTimeoutMs)
        load(.displayLimit, &displayLimit); load(.markerLanguage, &markerLanguage)
        load(.fontName, &fontName); load(.fontSize, &fontSize); load(.textColor, &textColor)
        load(.backgroundColor, &backgroundColor); load(.alwaysOnTop, &alwaysOnTop)
        load(.terminalInput, &terminalInput); load(.terminalLocalEcho, &terminalLocalEcho)
        load(.terminalCRLF, &terminalCRLF); load(.presets, &presets); load(.presetsVisible, &presetsVisible)
        load(.stm32Speed, &stm32Speed); load(.stm32Reset, &stm32Reset); load(.stcSpeed, &stcSpeed)
        if presets.count != PresetString.count { presets = PresetString.defaults() }
    }

    private static let key = "SSCOMSettings.v1"

    /// UI-test mode (`-SSCOMEphemeralSettings YES`): start from defaults and never save, so tests
    /// don't touch the user's saved setup.
    static let ephemeral = UserDefaults.standard.bool(forKey: "SSCOMEphemeralSettings")

    static func load() -> AppSettings {
        if ephemeral { return AppSettings() }
        guard let data = UserDefaults.standard.data(forKey: key),
              let s = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return s
    }

    func save() {
        if Self.ephemeral { return }
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    /// Applies values from an imported sscom51.ini.
    mutating func merge(_ ini: LegacyIniSettings) {
        if !ini.presets.isEmpty { presets = ini.presets }
        if let v = ini.baudRate { serial.baudRate = v }
        if let v = ini.mainText { sendText = v }
        if let v = ini.mainHexText { sendHexText = v }
        if let v = ini.mainHexMode { send.hexMode = v }
        if let v = ini.timedSendInterval, v > 0 { timedSendInterval = v }
        if let v = ini.appendCRLF { send.appendCRLF = v }
        if let v = ini.hexDisplay { hexDisplay = v }
        if let v = ini.dtr { serial.dtr = v }
        if let v = ini.rts { serial.rts = v }
        if let v = ini.openAtStartup { openAtStartup = v }
        if let v = ini.timestamps { timestamps = v }
        if let v = ini.packetTimeoutMs, v > 0 { packetTimeoutMs = v }
        if let v = ini.remoteIP, !v.isEmpty { remoteHost = v }
        if let v = ini.remotePort { remotePort = v }
        if let v = ini.localPort { localPort = v }
        if let v = ini.checksumFirstByte, v > 0 { send.placement.firstByte = v }
        if let v = ini.effectiveChecksumKind { send.checksum = v }
    }

    /// Replaces the send strings with a built-in set and sets the checksum it needs.
    /// The port is only changed while disconnected, so the box never disagrees with the open link.
    mutating func load(_ set: PresetSet, connected: Bool) {
        presets = set.presets
        send.checksum = set.checksum
        send.placement = ChecksumPlacement()
        if mode == .tcpClient, !connected { remotePort = set.port }
    }
}
