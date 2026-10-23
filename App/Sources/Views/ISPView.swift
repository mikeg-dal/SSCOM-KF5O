import SwiftUI
import SSCOMKit

/// The STM32/GD32 and STC/IAP15 in-system programmers (SSCOM's "Tools" tabs).
struct ISPView: View {
    @Bindable var session: Session
    let kind: Session.ISPKind
    @State private var hexFile: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("Open HEX File…") { hexFile = session.chooseHexFile() }
                Text(hexFile?.lastPathComponent ?? String(localized: "No file"))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Group {
                if kind == .stm32 { stm32Options } else { stcOptions }
            }
            HStack {
                Button(kind == .stm32 ? "Start Download STM/GD32" : "Start Download STC/IAP15") {
                    if let hexFile { session.startISP(kind, file: hexFile) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(hexFile == nil || session.ispRunning || session.settings.mode != .serial)
                Button("Stop") { session.stop() }
                    .disabled(!session.ispRunning)
                if let p = session.progress, session.ispRunning {
                    ProgressView(value: p).frame(width: 160)
                }
            }
            if session.settings.mode != .serial {
                Text("Switch the link to Serial Port and select the port wired to the MCU.")
                    .foregroundStyle(.orange)
            }
            ScrollView {
                Text(kind == .stm32 ? HelpText.stm32 : HelpText.stc)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            Text("Progress and messages appear in the main receive window.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding()
        .frame(minWidth: 460, minHeight: 360)
    }

    private var stm32Options: some View {
        Form {
            Picker("Speed", selection: $session.settings.stm32Speed) {
                Text("115200 bps — about 10 s per 64 KB (built-in serial port)").tag(STM32Flasher.Speed.normal)
                Text("460800 bps — about 5 s per 64 KB (CH340 and other USB adapters)").tag(STM32Flasher.Speed.fast)
            }
            Picker("Reset & BOOT0", selection: $session.settings.stm32Reset.mode) {
                ForEach(ResetControl.Mode.allCases) { Text($0.displayName).tag($0) }
            }
            if session.settings.stm32Reset.mode != .manual {
                Toggle("Invert RESET line", isOn: $session.settings.stm32Reset.invertReset)
                Toggle("Invert BOOT0 line", isOn: $session.settings.stm32Reset.invertBoot)
            }
        }
    }

    private var stcOptions: some View {
        Form {
            Picker("Speed", selection: $session.settings.stcSpeed) {
                Text("115200 bps — about 15 s per 64 KB (built-in serial port)").tag(STCFlasher.Speed.normal)
                Text("230400 bps — about 11 s per 64 KB (USB adapter)").tag(STCFlasher.Speed.faster)
                Text("460800 bps — about 8.8 s per 64 KB (CH340 and other USB adapters)").tag(STCFlasher.Speed.fastest)
            }
        }
    }
}

struct StatusBar: View {
    let session: Session

    var body: some View {
        HStack(spacing: 14) {
            Text(statusText)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if session.settings.mode == .serial, session.isOpen {
                line("CTS", .cts)
                line("DSR", .dsr)
                line("DCD", .dcd)
                line("RI", .ring)
            }
            Button {
                session.resetCounters()
            } label: {
                Text("S:\(session.sentCount)  R:\(session.receivedCount)")
                    .monospacedDigit()
            }
            .buttonStyle(.borderless)
            .help("Bytes sent and received. Click to reset.")
            if session.display.characterCount > 200_000 {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .help("The receive window holds a lot of data. Use “Receive to file” for long captures.")
            }
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.bar)
    }

    private var statusText: String {
        if session.isOpening { return String(localized: "Opening…") }
        if session.isOpen { return session.linkDescription }
        return String(localized: "Closed")
    }

    private func line(_ name: String, _ bit: ModemLines) -> some View {
        HStack(spacing: 3) {
            Circle()
                .fill(session.modemLines.contains(bit) ? Color.green : Color.secondary.opacity(0.3))
                .frame(width: 7, height: 7)
            Text(name)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(session.modemLines.contains(bit) ? "on" : "off")
    }
}
