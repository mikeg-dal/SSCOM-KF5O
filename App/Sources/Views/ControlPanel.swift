import SwiftUI
import SSCOMKit

/// The bottom half of the SSCOM window: link selection, display options and sending.
struct ControlPanel: View {
    @Bindable var session: Session
    @State private var showSerialSettings = false
    @State private var showChecksumHelp = false
    @FocusState private var sendFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            linkRow
            displayRow
            Divider()
            sendOptionsRow
            sendBox
            fileRow
            if let p = session.progress {
                ProgressView(value: p).progressViewStyle(.linear)
            }
        }
        .padding(10)
        .controlSize(.small)
    }

    // MARK: Link

    private var linkRow: some View {
        HStack(spacing: 8) {
            Picker("Link", selection: $session.settings.mode) {
                ForEach(LinkMode.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .disabled(session.isOpen)
            .help("Serial port or network link")
            .accessibilityIdentifier("link.mode")

            switch session.settings.mode {
            case .serial: serialControls
            case .tcpClient: networkControls(remote: true, local: true, localHost: false)
            case .tcpServer: networkControls(remote: false, local: true, localHost: true)
            case .udp: networkControls(remote: true, local: true, localHost: false)
            }

            Button {
                Task { await session.toggleOpen() }
            } label: {
                Label(openTitle, systemImage: session.isOpen ? "stop.circle.fill" : "play.circle.fill")
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            .tint(session.isOpen ? .red : .accentColor)
            .buttonStyle(.borderedProminent)
            .disabled(session.ispRunning)
            .accessibilityIdentifier("link.open")

            Circle()
                .fill(session.isOpen ? Color.red : Color.secondary.opacity(0.3))
                .frame(width: 10, height: 10)
                .accessibilityLabel(session.isOpen ? "Open" : "Closed")
            Spacer(minLength: 0)
        }
    }

    private var openTitle: LocalizedStringKey {
        switch session.settings.mode {
        case .serial: session.isOpen ? "Close Port" : "Open Port"
        case .tcpServer: session.isOpen ? "Stop" : "Listen"
        case .udp: session.isOpen ? "Stop" : "Start"
        case .tcpClient: session.isOpen ? "Disconnect" : "Connect"
        }
    }

    @ViewBuilder private var serialControls: some View {
        Picker("Port", selection: $session.settings.portPath) {
            if session.ports.isEmpty { Text("No ports").tag(String?.none) }
            ForEach(session.ports) { Text($0.displayName).tag(Optional($0.path)) }
            if session.currentPortMissing, let p = session.settings.portPath {
                Text("\(p) (unplugged)").tag(Optional(p))
            }
        }
        .labelsHidden()
        .fixedSize()
        .disabled(session.isOpen)
        .help("Serial port")

        Button {
            session.refreshPorts()
        } label: {
            Image(systemName: "arrow.clockwise")
        }
        .help("Refresh the port list")

        BaudField(baud: $session.settings.serial.baudRate) { session.applySerialSettings() }

        Button("More…") { showSerialSettings = true }
            .help("Data bits, stop bits, parity and flow control")
            .popover(isPresented: $showSerialSettings) {
                SerialSettingsView(session: session).padding().frame(width: 300)
            }

        Toggle("DTR", isOn: Binding(get: { session.settings.serial.dtr }, set: { session.setDTR($0) }))
        Toggle("RTS", isOn: Binding(get: { session.settings.serial.rts }, set: { session.setRTS($0) }))
            .disabled(session.settings.serial.flowControl == .hardware)
    }

    @ViewBuilder
    private func networkControls(remote: Bool, local: Bool, localHost: Bool) -> some View {
        Group { networkFields(remote: remote, local: local, localHost: localHost) }
            .disabled(session.isOpen)
    }

    @ViewBuilder
    private func networkFields(remote: Bool, local: Bool, localHost: Bool) -> some View {
        if remote {
            Text("Remote")
            TextField("Host or IP", text: $session.settings.remoteHost)
                .frame(width: 150)
                .accessibilityIdentifier("remote.host")
            TextField("Port", value: $session.settings.remotePort, format: .number.grouping(.never))
                .frame(width: 60)
                .accessibilityIdentifier("remote.port")
        }
        if local {
            Text("Local")
            if localHost {
                Picker("Local IP", selection: $session.settings.localHost) {
                    ForEach(session.localAddresses, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(width: 140)
            }
            TextField("Port", value: $session.settings.localPort, format: .number.grouping(.never))
                .frame(width: 60)
                .help(session.settings.mode == .tcpClient ? "Local port to bind (0 = any)" : "Local port")
        }
    }

    // MARK: Display

    private var displayRow: some View {
        HStack(spacing: 12) {
            Toggle("HEX display", isOn: $session.settings.hexDisplay)
            Toggle("Show time and packets", isOn: $session.settings.timestamps)
                .help("Each packet starts on a new line with a timestamp. TX marks sent data, RX marks received data.")
            HStack(spacing: 2) {
                Text("Timeout")
                TextField("ms", value: $session.settings.packetTimeoutMs, format: .number.grouping(.never))
                    .frame(width: 44)
                Text("ms")
            }
            .disabled(!session.settings.timestamps)
            .help("Gap that splits received data into packets. It must be shorter than the gap between packets.")
            Spacer()
            Toggle("Receive to file", isOn: Binding(get: { session.receiveFileURL != nil },
                                                   set: { _ in session.toggleReceiveToFile() }))
                .help(session.receiveFileURL?.path ?? "Save every received byte to a file")
            Button("Save Data…") { session.saveData() }
                .help("Save the window text and the raw received data")
            Button("Clear") { session.clearWindow() }
                .keyboardShortcut("k", modifiers: .command)
        }
    }

    // MARK: Send

    private var sendOptionsRow: some View {
        HStack(spacing: 12) {
            Toggle("HEX send", isOn: $session.settings.send.hexMode)
            Toggle("Add CR LF", isOn: $session.settings.send.appendCRLF)
                .disabled(session.settings.send.hexMode)
                .help("Append carriage return and line feed (string mode only)")
            HStack(spacing: 2) {
                Toggle("Timed send", isOn: $session.timedSendEnabled)
                    .disabled(!session.isOpen)
                TextField("ms", value: $session.settings.timedSendInterval, format: .number.grouping(.never))
                    .frame(width: 54)
                Text("ms")
            }
            Spacer()
            checksumControls
        }
    }

    private var checksumControls: some View {
        HStack(spacing: 4) {
            Text("Checksum from byte")
            TextField("1", value: $session.settings.send.placement.firstByte, format: .number.grouping(.never))
                .frame(width: 30)
                .help("1 = check the whole frame. Use 3 to skip a 2-byte frame header.")
            Text("to")
            Picker("to", selection: $session.settings.send.placement.trailerBytes) {
                Text("End").tag(0)
                ForEach(1...4, id: \.self) { n in Text("−\(n) (\(n)-byte tail)").tag(n) }
            }
            .labelsHidden()
            .fixedSize()
            Picker("Checksum", selection: $session.settings.send.checksum) {
                ForEach(ChecksumKind.allCases) { Text($0.displayName).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("send.checksum")
            Text(session.lastChecksum)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(minWidth: 40, alignment: .leading)
                .textSelection(.enabled)
            Button {
                showChecksumHelp = true
            } label: {
                Image(systemName: "questionmark.circle")
            }
            .buttonStyle(.borderless)
            .popover(isPresented: $showChecksumHelp) {
                ScrollView { Text(HelpText.checksum).padding().textSelection(.enabled) }
                    .frame(width: 460, height: 380)
            }
        }
    }

    private var sendBox: some View {
        HStack(alignment: .top, spacing: 8) {
            TextEditor(text: session.settings.send.hexMode ? $session.settings.sendHexText : $session.settings.sendText)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(.background, in: .rect(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                .frame(minHeight: 54, maxHeight: 90)
                .focused($sendFocused)
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.command) || press.modifiers.contains(.control) else { return .ignored }
                    Task { await session.sendMain() }
                    return .handled
                }
                .help("Press ⌘↩ or ⌃↩ to send. Escapes: \\r \\n \\t \\x41 \\\\ \\0")
                .accessibilityLabel("Data to send")
            Button {
                Task { await session.sendMain() }
            } label: {
                Text("Send").frame(minWidth: 60, minHeight: 40)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!session.isOpen)
        }
    }

    private var fileRow: some View {
        HStack(spacing: 8) {
            Text(session.fileToSend?.lastPathComponent ?? String(localized: "No file selected"))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 220, alignment: .leading)
            Button("Open File…") { session.chooseFileToSend() }
            Button("Send File") { session.sendFile() }
                .disabled(!session.isOpen || session.fileToSend == nil)
            Button("Stop") { session.stop() }
                .disabled(session.progress == nil && !session.timedSendEnabled && !session.presetLoopEnabled)
            Spacer()
            Toggle("Strings panel", isOn: $session.settings.presetsVisible)
                .accessibilityIdentifier("panel.strings")
                .toggleStyle(.button)
                .help("Show the 99 user-defined strings")
            Toggle("Always on top", isOn: $session.settings.alwaysOnTop)
        }
    }
}

/// Baud rate combo box: pick a standard rate or type any custom rate (110 bps to 50 Mbps).
struct BaudField: View {
    @Binding var baud: Int
    var onCommit: () -> Void
    @State private var text = ""

    var body: some View {
        HStack(spacing: 2) {
            TextField("Baud", text: $text)
                .frame(width: 80)
                .onSubmit(commit)
                .onAppear { text = String(baud) }
                .onChange(of: baud) { text = String(baud) }
            Menu {
                ForEach(SerialSettings.standardBaudRates.reversed(), id: \.self) { rate in
                    Button(String(rate)) { baud = rate; onCommit() }
                }
            } label: {
                Image(systemName: "chevron.down")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            Text("bps").foregroundStyle(.secondary).fixedSize()
        }
        .help("Baud rate. Type a custom value and press Return.")
    }

    private func commit() {
        guard let v = Int(text.trimmingCharacters(in: .whitespaces)), SerialSettings.baudRange.contains(v) else {
            text = String(baud)
            NSSound.beep()
            return
        }
        baud = v
        onCommit()
    }
}

struct SerialSettingsView: View {
    @Bindable var session: Session

    var body: some View {
        Form {
            Picker("Data bits", selection: $session.settings.serial.dataBits) {
                ForEach([5, 6, 7, 8], id: \.self) { Text("\($0)").tag($0) }
            }
            Picker("Stop bits", selection: $session.settings.serial.stopBits) {
                Text("1").tag(StopBits.one)
                Text("2").tag(StopBits.two)
            }
            Picker("Parity", selection: $session.settings.serial.parity) {
                ForEach(Parity.allCases) { Text($0.displayName).tag($0) }
            }
            Picker("Flow control", selection: $session.settings.serial.flowControl) {
                ForEach(FlowControl.allCases) { Text($0.displayName).tag($0) }
            }
            Toggle("Reconnect when the USB adapter is plugged back in", isOn: $session.settings.autoReconnect)
        }
        .onChange(of: session.settings.serial) { session.applySerialSettings() }
    }
}
