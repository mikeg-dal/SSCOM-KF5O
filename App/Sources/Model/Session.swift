import AppKit
import SSCOMKit
import UniformTypeIdentifiers

/// The state of one SSCOM window: the open link, traffic, and every send feature.
@Observable
final class Session {
    var settings: AppSettings {
        didSet {
            settings.save()
            if settings.displayOptions != oldValue.displayOptions { rerender() }
            if settings.displayLimit != oldValue.displayLimit { log.limit = settings.displayLimit }
            if settings.fontName != oldValue.fontName || settings.fontSize != oldValue.fontSize
                || settings.textColor != oldValue.textColor || settings.backgroundColor != oldValue.backgroundColor {
                applyDisplayStyle()
            }
        }
    }

    // Link state
    private(set) var ports: [SerialPortInfo] = []
    private(set) var isOpen = false
    private(set) var isOpening = false
    private(set) var linkDescription = ""
    private(set) var modemLines = ModemLines()
    private(set) var localAddresses: [String] = NetworkInterfaces.ipv4Addresses()

    // Counters
    private(set) var sentCount = 0
    private(set) var receivedCount = 0

    // Activity
    var timedSendEnabled = false { didSet { updateTimedSend() } }
    var presetLoopEnabled = false { didSet { updatePresetLoop() } }
    private(set) var activePresetID: Int?
    private(set) var lastChecksum = ""
    private(set) var fileToSend: URL?
    private(set) var progress: Double?
    private(set) var ispRunning = false
    private(set) var receiveFileURL: URL?
    var alert: AlertInfo?

    struct AlertInfo: Identifiable {
        let id = UUID()
        var title: String
        var message: String
    }

    let display = ReceiveDisplay()
    private(set) var log = TrafficLog()

    @ObservationIgnored private var transport: (any ByteTransport)?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var renderer: TrafficRenderer
    @ObservationIgnored private var lastSegmentDirection: Direction?
    @ObservationIgnored private var timedSendTask: Task<Void, Never>?
    @ObservationIgnored private var presetLoopTask: Task<Void, Never>?
    @ObservationIgnored private var fileSendTask: Task<Void, Never>?
    @ObservationIgnored private var ispTask: Task<Void, Never>?
    @ObservationIgnored private var ispReplies: ReplyBuffer?
    @ObservationIgnored private var receiveFile: FileHandle?
    @ObservationIgnored private var reconnectPath: String?
    @ObservationIgnored private var terminalLine = ""
    @ObservationIgnored private let enumerator = SerialPortEnumerator()

    init() {
        let s = AppSettings.load()
        settings = s
        renderer = TrafficRenderer(options: s.displayOptions)
        log.limit = s.displayLimit
        applyDisplayStyle()
        Task { [weak self] in
            guard let updates = self?.enumerator.updates else { return }
            for await list in updates {
                self?.portsChanged(list)
            }
        }
        if s.openAtStartup {
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                await self?.open()
            }
        }
    }

    // MARK: - Ports

    private func portsChanged(_ list: [SerialPortInfo]) {
        ports = list
        if settings.portPath == nil || !list.contains(where: { $0.path == settings.portPath }) {
            // Keep a vanished port selected so it can reconnect when replugged (as SSCOM did).
            if settings.portPath == nil || reconnectPath == nil, !isOpen, let first = list.first {
                settings.portPath = first.path
            }
        }
        if let path = reconnectPath, list.contains(where: { $0.path == path }), !isOpen, settings.autoReconnect {
            systemMessage(String(localized: "Port \(path) is back, reconnecting..."))
            Task { await open() }
        }
    }

    func refreshPorts() {
        portsChanged(SerialPortEnumerator.currentPorts())
        localAddresses = NetworkInterfaces.ipv4Addresses()
    }

    var currentPortMissing: Bool {
        guard settings.mode == .serial, let p = settings.portPath else { return false }
        return !ports.contains { $0.path == p }
    }

    // MARK: - Open / close

    func toggleOpen() async {
        if isOpen || isOpening { close() } else { await open() }
    }

    func open() async {
        guard !isOpen, !isOpening else { return }
        let t: any ByteTransport
        switch settings.mode {
        case .serial:
            guard let path = settings.portPath else {
                alert = AlertInfo(title: String(localized: "No serial port"), message: String(localized: "Select a serial port first."))
                return
            }
            t = SerialPort(path: path, settings: settings.serial)
            systemMessage(String(localized: "Opening \(path)..."))
        case .tcpClient:
            t = TCPClientTransport(host: settings.remoteHost, port: UInt16(clamping: settings.remotePort),
                                   localPort: UInt16(clamping: settings.localPort))
        case .tcpServer:
            t = TCPServerTransport(port: UInt16(clamping: settings.localPort), localHost: settings.localHost)
        case .udp:
            t = UDPTransport(remoteHost: settings.remoteHost, remotePort: UInt16(clamping: settings.remotePort),
                             localPort: UInt16(clamping: settings.localPort))
        }
        isOpening = true
        transport = t
        eventTask = Task { [weak self] in
            for await event in t.events {
                self?.handle(event)
            }
        }
        do {
            try await t.open()
            reconnectPath = nil
        } catch {
            isOpening = false
            transport = nil
            eventTask?.cancel()
            let message = settings.mode == .serial
                ? String(localized: """
                    Unable to open the serial port.
                    • Is the USB adapter loose?
                    • Is the baud rate too high? Try 115200, 8, 1, None, None.
                    • Is it in use by another program?

                    \(error.localizedDescription)
                    """)
                : error.localizedDescription
            systemMessage(error.localizedDescription)
            alert = AlertInfo(title: String(localized: "Unable to open"), message: message)
        }
    }

    func close() {
        reconnectPath = nil
        stopActivities()
        transport?.close()
    }

    private func stopActivities() {
        timedSendEnabled = false
        presetLoopEnabled = false
        fileSendTask?.cancel()
        ispTask?.cancel()
    }

    private func handle(_ event: TransportEvent) {
        switch event {
        case .opened(let description):
            isOpening = false
            isOpen = true
            linkDescription = description
            systemMessage(String(localized: "Opened: \(description)"))
        case .received(let bytes):
            received(bytes)
        case .status(let s):
            linkDescription = s
            systemMessage(s)
        case .modemLines(let lines):
            modemLines = lines
        case .closed(let error):
            let wasOpen = isOpen
            isOpen = false
            isOpening = false
            transport = nil
            modemLines = []
            stopActivities()
            if let error {
                systemMessage(String(localized: "Link error: \(error)"))
                if settings.mode == .serial, settings.autoReconnect, wasOpen {
                    reconnectPath = settings.portPath
                    systemMessage(String(localized: "Waiting for the port to come back (auto repair)..."))
                }
            } else {
                systemMessage(String(localized: "Closed."))
            }
            linkDescription = ""
        }
    }

    // MARK: - Receive and display

    private func received(_ bytes: [UInt8]) {
        receivedCount += bytes.count
        if let ispReplies {
            ispReplies.append(bytes)
            return
        }
        try? receiveFile?.write(contentsOf: bytes)
        record(bytes, direction: .received)
    }

    private func record(_ bytes: [UInt8], direction: Direction) {
        let result = log.append(bytes, direction: direction, at: .now,
                                packetTimeout: Double(settings.packetTimeoutMs) / 1000)
        switch result {
        case .trimmed:
            rerender()
        case .extended:
            display.append(renderer.body(bytes, direction: direction))
        case .newSegment(let index):
            let seg = log.segments[index]
            var text = ""
            if lastSegmentDirection == .received { text += renderer.endReceivedSegment() }
            if !settings.timestamps, direction == .sent {
                lastSegmentDirection = .sent
                display.append(text)
                return
            }
            let header = renderer.header(for: seg, isFirst: display.characterCount == 0 && text.isEmpty)
            renderer.note(header)
            text += header
            text += renderer.body(seg.bytes, direction: direction)
            let footer = renderer.footer(for: seg)
            renderer.note(footer)
            text += footer
            display.append(text)
        }
        lastSegmentDirection = direction
    }

    /// Rebuilds the receive window from the traffic log in the current display mode.
    func rerender() {
        renderer = TrafficRenderer(options: settings.displayOptions)
        display.replace(with: renderer.render(log))
        lastSegmentDirection = log.segments.last?.direction
    }

    /// Messages from the app itself (not traffic), shown inline like SSCOM did.
    func systemMessage(_ text: String) {
        display.append((display.characterCount == 0 || renderer.atLineStart ? "" : "\n") + text + "\n")
        renderer.atLineStart = true
    }

    func clearWindow() {
        log.removeAll()
        renderer = TrafficRenderer(options: settings.displayOptions)
        lastSegmentDirection = nil
        display.clear()
    }

    func resetCounters() {
        sentCount = 0
        receivedCount = 0
    }

    private func applyDisplayStyle() {
        display.font = NSFont(name: settings.fontName, size: settings.fontSize)
            ?? .monospacedSystemFont(ofSize: settings.fontSize, weight: .regular)
        display.textColor = settings.textColor.nsColor
        display.backgroundColor = settings.backgroundColor.nsColor
        display.applyStyle()
    }

    // MARK: - Sending

    /// Sends `text` with the panel's options; returns false if it couldn't be built or sent.
    @discardableResult
    func send(_ text: String, hex: Bool) async -> Bool {
        guard transport != nil, isOpen else {
            alert = AlertInfo(title: String(localized: "Not open"), message: String(localized: "Open the port or connection first."))
            return false
        }
        let result: ChecksumResult
        do {
            result = try PayloadBuilder.build(text, hex: hex, options: settings.send)
        } catch {
            alert = AlertInfo(title: String(localized: "Invalid data"), message: error.localizedDescription)
            return false
        }
        if result.rangeWasEmpty {
            alert = AlertInfo(title: String(localized: "Checksum not added"),
                              message: String(localized: "The data to check is 0 bytes long. Check the first-byte and frame-tail settings; no checksum was added."))
        }
        lastChecksum = HexCodec.format(result.checksum).trimmingCharacters(in: .whitespaces)
        return await sendRaw(result.frame)
    }

    @discardableResult
    func sendRaw(_ bytes: [UInt8], showInLog: Bool = true) async -> Bool {
        guard let transport, !bytes.isEmpty else { return false }
        do {
            try await transport.write(bytes)
            sentCount += bytes.count
            if showInLog { record(bytes, direction: .sent) }
            return true
        } catch {
            systemMessage(String(localized: "Send failed: \(error.localizedDescription)"))
            return false
        }
    }

    func sendMain() async {
        let hex = settings.send.hexMode
        await send(hex ? settings.sendHexText : settings.sendText, hex: hex)
    }

    private func updateTimedSend() {
        timedSendTask?.cancel()
        guard timedSendEnabled else { return }
        guard isOpen else { timedSendEnabled = false; return }
        guard settings.timedSendInterval > 0 else {
            alert = AlertInfo(title: String(localized: "Set an interval"), message: String(localized: "Please enter a non-zero interval."))
            timedSendEnabled = false
            return
        }
        timedSendTask = Task { [weak self] in
            while !Task.isCancelled, let self {
                if await !self.send(self.settings.send.hexMode ? self.settings.sendHexText : self.settings.sendText,
                                    hex: self.settings.send.hexMode) {
                    self.timedSendEnabled = false
                    return
                }
                try? await Task.sleep(for: .milliseconds(max(self.settings.timedSendInterval, 1)))
            }
        }
    }

    // MARK: - Preset strings

    func sendPreset(_ id: Int) async {
        guard let p = settings.presets.first(where: { $0.id == id }), !p.text.isEmpty else { return }
        activePresetID = id
        await send(p.text, hex: p.hex)
    }

    private func updatePresetLoop() {
        presetLoopTask?.cancel()
        activePresetID = nil
        guard presetLoopEnabled else { return }
        guard isOpen else { presetLoopEnabled = false; return }
        presetLoopTask = Task { [weak self] in
            while !Task.isCancelled, let self {
                let sequence = PresetString.loopSequence(self.settings.presets)
                guard !sequence.isEmpty else {
                    self.presetLoopEnabled = false
                    self.alert = AlertInfo(title: String(localized: "Nothing to send"),
                                           message: String(localized: "Give at least one string an order number above 0."))
                    return
                }
                for p in sequence {
                    if Task.isCancelled { return }
                    self.activePresetID = p.id
                    if await !self.send(p.text, hex: p.hex) { self.presetLoopEnabled = false; return }
                    try? await Task.sleep(for: .milliseconds(max(p.delayMs, 1)))
                }
            }
        }
    }

    func importLegacyIni() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "ini") ?? .plainText, .plainText]
        panel.message = String(localized: "Choose an SSCOM sscom51.ini file to import its strings and settings.")
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        let ini = LegacyIniImporter.load(data)
        settings.merge(ini)
        systemMessage(String(localized: "Imported \(ini.presets.filter { !$0.text.isEmpty }.count) strings from \(url.lastPathComponent)."))
    }

    // MARK: - Files

    func chooseFileToSend() {
        let panel = NSOpenPanel()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        fileToSend = url
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int {
            systemMessage(String(localized: "File: \(url.lastPathComponent), size \(size) bytes."))
        }
    }

    func sendFile() {
        guard let url = fileToSend else { chooseFileToSend(); return }
        guard isOpen else {
            alert = AlertInfo(title: String(localized: "Not open"), message: String(localized: "Open the port or connection first."))
            return
        }
        guard let data = try? Data(contentsOf: url) else {
            alert = AlertInfo(title: String(localized: "File read error"),
                              message: String(localized: "The file does not exist or is opened by another program."))
            return
        }
        let delay = settings.fileSendDelay.rawValue
        let bytes = [UInt8](data)
        if settings.mode == .serial {
            let seconds = Double(bytes.count * 10) / Double(settings.serial.baudRate) + Double(bytes.count / 256 * delay) / 1000
            systemMessage(String(localized: "Sending \(bytes.count) bytes at \(settings.serial.baudRate) bps, about \(String(format: "%.1f", seconds)) s. Please wait..."))
        }
        fileSendTask?.cancel()
        progress = 0
        fileSendTask = Task { [weak self] in
            guard let self else { return }
            var offset = 0
            while offset < bytes.count {
                if Task.isCancelled {
                    self.systemMessage(String(localized: "User abort!"))
                    self.progress = nil
                    return
                }
                let chunk = Array(bytes[offset..<min(offset + 256, bytes.count)])
                guard await self.sendRaw(chunk, showInLog: false) else { break }
                offset += chunk.count
                self.progress = Double(offset) / Double(bytes.count)
                if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
            }
            self.progress = nil
            self.systemMessage(String(localized: "Send complete! (\(offset) bytes)"))
        }
    }

    func stop() {
        fileSendTask?.cancel()
        ispTask?.cancel()
        timedSendEnabled = false
        presetLoopEnabled = false
    }

    private static var stamp: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f.string(from: .now)
    }

    /// Saves the window text and the raw received bytes as two files, like SSCOM's "Save data".
    func saveData() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Save Here")
        panel.message = String(localized: "Choose a folder for the window text and the raw received data.")
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        let stamp = Self.stamp
        let textURL = dir.appending(path: "SSCOM_\(stamp)_window.txt")
        let rawURL = dir.appending(path: "SSCOM_\(stamp)_raw.dat")
        do {
            try display.text.write(to: textURL, atomically: true, encoding: .utf8)
            try Data(log.receivedBytes).write(to: rawURL)
            systemMessage(String(localized: "Window contents saved to \(textURL.path)\nRaw received data saved to \(rawURL.path)"))
        } catch {
            alert = AlertInfo(title: String(localized: "Unable to save"), message: error.localizedDescription)
        }
    }

    /// Starts or stops writing every received byte to a file.
    func toggleReceiveToFile() {
        if let receiveFile {
            try? receiveFile.close()
            self.receiveFile = nil
            receiveFileURL = nil
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "SSCOM_\(Self.stamp)_receive.dat"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let h = try? FileHandle(forWritingTo: url) else {
            alert = AlertInfo(title: String(localized: "Unable to save"), message: String(localized: "The file can't be written."))
            return
        }
        receiveFile = h
        receiveFileURL = url
        systemMessage(String(localized: "Received data will be saved to: \(url.path)"))
    }

    // MARK: - Serial lines

    func setDTR(_ on: Bool) {
        settings.serial.dtr = on
        do { try (transport as? SerialPort)?.setDTR(on) } catch {
            alert = AlertInfo(title: String(localized: "Unable to set DTR"), message: error.localizedDescription)
        }
    }

    func setRTS(_ on: Bool) {
        settings.serial.rts = on
        do { try (transport as? SerialPort)?.setRTS(on) } catch {
            alert = AlertInfo(title: String(localized: "Unable to set RTS"), message: error.localizedDescription)
        }
    }

    /// Applies baud rate and framing changes to the open port immediately.
    func applySerialSettings() {
        guard let port = transport as? SerialPort else { return }
        do { try port.reconfigure(settings.serial) } catch {
            alert = AlertInfo(title: String(localized: "Unsupported setting"), message: error.localizedDescription)
        }
    }

    // MARK: - Terminal emulation

    /// Handles a key typed into the receive window.
    func terminalKey(_ event: NSEvent) {
        guard isOpen else { NSSound.beep(); return }
        var bytes: [UInt8]
        switch event.keyCode {
        case 126: bytes = [0x1B, 0x5B, 0x41] // up
        case 125: bytes = [0x1B, 0x5B, 0x42] // down
        case 124: bytes = [0x1B, 0x5B, 0x43] // right
        case 123: bytes = [0x1B, 0x5B, 0x44] // left
        case 51: bytes = [0x08]              // delete (backspace)
        case 117: bytes = [0x7F]             // forward delete
        case 53: bytes = [0x1B]              // escape
        default:
            guard let chars = event.characters, !chars.isEmpty,
                  let data = chars.data(using: settings.send.encoding.stringEncoding) else { return }
            bytes = Array(data)
        }
        let isReturn = bytes == [0x0D]
        if isReturn, settings.terminalCRLF { bytes = [0x0D, 0x0A] }

        switch settings.terminalInput {
        case .keystroke:
            if settings.terminalLocalEcho { display.append(isReturn ? "\n" : (event.characters ?? "")) }
            Task { await sendRaw(bytes, showInLog: false) }
        case .line:
            if isReturn {
                display.append("\n")
                var line = Array(terminalLine.data(using: settings.send.encoding.stringEncoding) ?? Data())
                line += bytes
                terminalLine = ""
                Task { await sendRaw(line, showInLog: false) }
            } else if bytes == [0x08] {
                if !terminalLine.isEmpty { terminalLine.removeLast() }
            } else if let c = event.characters, bytes.first.map({ $0 >= 0x20 }) ?? false {
                terminalLine += c
                display.append(c)
            } else {
                // Control characters such as Ctrl+Z (0x1A) are sent straight away.
                Task { await sendRaw(bytes, showInLog: false) }
            }
        }
    }

    func terminalPaste(_ text: String) {
        guard isOpen, let data = text.data(using: settings.send.encoding.stringEncoding) else { return }
        Task { await sendRaw(Array(data)) }
    }

    // MARK: - ISP

    enum ISPKind { case stm32, stc }

    func chooseHexFile() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "hex") ?? .data, UTType(filenameExtension: "ihx") ?? .data]
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    func startISP(_ kind: ISPKind, file: URL) {
        guard settings.mode == .serial else {
            alert = AlertInfo(title: String(localized: "Serial port required"),
                              message: String(localized: "Select the serial port connected to the MCU."))
            return
        }
        ispTask?.cancel()
        ispTask = Task { [weak self] in
            guard let self else { return }
            let image: FirmwareImage
            do {
                let text = try String(contentsOf: file, encoding: .ascii)
                image = try IntelHex.parse(text)
            } catch {
                self.systemMessage(String(localized: "The file is not a HEX file! \(error.localizedDescription)"))
                return
            }
            if !self.isOpen { await self.open() }
            guard let port = self.transport as? SerialPort else { return }
            self.stopTimedActivitiesForISP()
            let replies = ReplyBuffer()
            self.ispReplies = replies
            self.ispRunning = true
            self.progress = 0
            let link = SerialISPLink(port: port, replies: replies)
            let original = self.settings.serial
            let events: @Sendable (ISPEvent) -> Void = { [weak self] event in
                Task { @MainActor in
                    switch event {
                    case .log(let s): self?.systemMessage(s)
                    case .progress(let done, let total): self?.progress = total > 0 ? Double(done) / Double(total) : nil
                    }
                }
            }
            self.systemMessage(String(localized: "HEX file \(file.lastPathComponent): \(image.byteCount) bytes"))
            do {
                switch kind {
                case .stm32:
                    try await STM32Flasher(speed: self.settings.stm32Speed, reset: self.settings.stm32Reset)
                        .flash(image, link: link, events: events)
                case .stc:
                    try await STCFlasher(speed: self.settings.stcSpeed)
                        .flash(image, link: link, originalBaud: original.baudRate, events: events)
                }
            } catch is CancellationError {
                self.systemMessage(String(localized: "User abort!"))
            } catch {
                self.systemMessage(error.localizedDescription)
            }
            // Restore the user's line settings.
            try? port.reconfigure(original)
            self.ispReplies = nil
            self.ispRunning = false
            self.progress = nil
        }
    }

    private func stopTimedActivitiesForISP() {
        timedSendEnabled = false
        presetLoopEnabled = false
        fileSendTask?.cancel()
    }
}
