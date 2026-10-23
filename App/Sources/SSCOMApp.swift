import SSCOMKit
import SwiftUI

@main
struct SSCOMApp: App {
    @State private var session = Session()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("SSCOM", id: "main") {
            ContentView(session: session)
        }
        .defaultSize(width: 1000, height: 680)
        .commands { commands }

        Window("Data Waveform", id: "waveform") {
            WaveformView(session: session)
        }
        .defaultSize(width: 820, height: 420)

        Window("STM32 / GD32 ISP", id: "isp-stm32") {
            ISPView(session: session, kind: .stm32)
        }
        .windowResizability(.contentSize)

        Window("STC / IAP15 ISP", id: "isp-stc") {
            ISPView(session: session, kind: .stc)
        }
        .windowResizability(.contentSize)

        Window("SSCOM Help", id: "help") {
            HelpView()
        }

        Settings {
            SettingsView(session: session)
        }
    }

    @CommandsBuilder private var commands: some Commands {
        CommandGroup(replacing: .newItem) {}
        CommandMenu("Port") {
            Button(session.isOpen ? "Close" : "Open") { Task { await session.toggleOpen() } }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Button("Refresh Port List") { session.refreshPorts() }
                .keyboardShortcut("r", modifiers: .command)
            Divider()
            Picker("Link", selection: $session.settings.mode) {
                ForEach(LinkMode.allCases) { Text($0.title).tag($0) }
            }
            .disabled(session.isOpen)
            Divider()
            Toggle("Open Port at Startup", isOn: $session.settings.openAtStartup)
            Toggle("Auto-Reconnect USB Adapters", isOn: $session.settings.autoReconnect)
        }
        CommandMenu("Send") {
            Button("Send") { Task { await session.sendMain() } }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!session.isOpen)
            Toggle("Timed Send", isOn: $session.timedSendEnabled)
                .disabled(!session.isOpen)
            Divider()
            Picker("Terminal Typing", selection: $session.settings.terminalInput) {
                Text("Send Each Key Immediately").tag(TerminalInputMode.keystroke)
                Text("Send Line on Return (with Echo)").tag(TerminalInputMode.line)
            }
            Toggle("Echo Keys Locally", isOn: $session.settings.terminalLocalEcho)
            Toggle("Send LF After CR", isOn: $session.settings.terminalCRLF)
            Divider()
            Picker("File Send Speed", selection: $session.settings.fileSendDelay) {
                ForEach(FileSendDelay.allCases) { Text($0.title).tag($0) }
            }
            Button("Open File…") { session.chooseFileToSend() }
            Button("Send File") { session.sendFile() }
                .disabled(!session.isOpen || session.fileToSend == nil)
            Button("Stop") { session.stop() }
                .keyboardShortcut(".", modifiers: .command)
        }
        CommandGroup(after: .toolbar) {
            Toggle("HEX Display", isOn: $session.settings.hexDisplay)
                .keyboardShortcut("h", modifiers: [.command, .shift])
            Toggle("Show Time and Packets", isOn: $session.settings.timestamps)
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Toggle("Strings Panel", isOn: $session.settings.presetsVisible)
                .keyboardShortcut("e", modifiers: [.command, .shift])
            Picker("Display Buffer Limit", selection: $session.settings.displayLimit) {
                ForEach(AppSettings.displayLimits, id: \.self) { n in
                    Text(n >= 1_000_000 ? "\(n / 1_000_000) MB" : "\(n / 1000) KB").tag(n)
                }
            }
            Button("Clear Window") { session.clearWindow() }
                .keyboardShortcut("k", modifiers: .command)
            Divider()
        }
        CommandMenu("Tools") {
            Button("Data Waveform (Oscilloscope)") { openWindow(id: "waveform") }
                .keyboardShortcut("w", modifiers: [.command, .option])
            Button("STM32 / GD32 ISP Programmer") { openWindow(id: "isp-stm32") }
            Button("STC / IAP15 ISP Programmer") { openWindow(id: "isp-stc") }
            Divider()
            Button("Import SSCOM ini…") { session.importLegacyIni() }
        }
        CommandGroup(replacing: .help) {
            Button("SSCOM Help") { openWindow(id: "help") }
                .keyboardShortcut("?", modifiers: .command)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save Data…") { session.saveData() }
                .keyboardShortcut("s", modifiers: .command)
            Button(session.receiveFileURL == nil ? "Receive to File…" : "Stop Receiving to File") {
                session.toggleReceiveToFile()
            }
        }
    }
}
