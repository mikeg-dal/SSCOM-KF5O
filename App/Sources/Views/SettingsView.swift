import SwiftUI
import SSCOMKit

struct SettingsView: View {
    @Bindable var session: Session

    var body: some View {
        TabView {
            Tab("Display", systemImage: "textformat") { display }
            Tab("Terminal", systemImage: "terminal") { terminal }
            Tab("Startup", systemImage: "power") { startup }
        }
        .frame(width: 480)
        .padding()
    }

    private var display: some View {
        Form {
            Picker("Font", selection: $session.settings.fontName) {
                ForEach(Self.monospacedFonts, id: \.self) { name in
                    Text(NSFont(name: name, size: 12)?.displayName ?? name).tag(name)
                }
            }
            Stepper("Size: \(Int(session.settings.fontSize)) pt", value: $session.settings.fontSize, in: 8...36)
            ColorPicker("Text color", selection: color(\.textColor), supportsOpacity: false)
            ColorPicker("Background color", selection: color(\.backgroundColor), supportsOpacity: false)
            Button("Reset Colors") {
                session.settings.textColor = StoredColor(.textColor)
                session.settings.backgroundColor = StoredColor(.textBackgroundColor)
            }
            Picker("Text encoding", selection: $session.settings.send.encoding) {
                ForEach(TextEncodingOption.allCases) { Text($0.displayName).tag($0) }
            }
            .help("Used to decode received text and encode sent strings. Chinese Windows devices often use GB18030/GBK.")
            Picker("Packet markers", selection: $session.settings.markerLanguage) {
                Text("Automatic").tag(MarkerLanguage.automatic)
                Text("English (TX / RX)").tag(MarkerLanguage.english)
                Text("Chinese (发 / 收)").tag(MarkerLanguage.chinese)
            }
            Picker("Display buffer limit", selection: $session.settings.displayLimit) {
                ForEach(AppSettings.displayLimits, id: \.self) { n in
                    Text(n >= 1_000_000 ? "\(n / 1_000_000) MB" : "\(n / 1000) KB").tag(n)
                }
            }
        }
    }

    private var terminal: some View {
        Form {
            Picker("Typing in the receive window", selection: $session.settings.terminalInput) {
                Text("Send each key immediately").tag(TerminalInputMode.keystroke)
                Text("Send the line on Return (with echo)").tag(TerminalInputMode.line)
            }
            .pickerStyle(.radioGroup)
            Toggle("Echo keys locally (immediate mode)", isOn: $session.settings.terminalLocalEcho)
                .disabled(session.settings.terminalInput != .keystroke)
            Toggle("Send LF (0x0A) after CR (0x0D)", isOn: $session.settings.terminalCRLF)
            Text(HelpText.general.components(separatedBy: "\n\n").first { $0.hasPrefix("Terminal") } ?? "")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var startup: some View {
        Form {
            Toggle("Open the port when SSCOM starts", isOn: $session.settings.openAtStartup)
            Toggle("Reconnect unplugged USB serial adapters", isOn: $session.settings.autoReconnect)
            Toggle("Keep window on top", isOn: $session.settings.alwaysOnTop)
        }
    }

    private func color(_ key: WritableKeyPath<AppSettings, StoredColor>) -> Binding<Color> {
        Binding(get: { Color(nsColor: session.settings[keyPath: key].nsColor) },
                set: { session.settings[keyPath: key] = StoredColor(NSColor($0)) })
    }

    static let monospacedFonts: [String] = {
        let names = NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? []
        let system = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular).fontName
        return [system] + names.filter { $0 != system && !$0.hasPrefix(".") }.sorted()
    }()
}
