import SwiftUI

struct ContentView: View {
    @Bindable var session: Session

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                ReceiveView(session: session)
                    .frame(minWidth: 420, minHeight: 200)
                if session.settings.presetsVisible {
                    PresetsPanel(session: session)
                }
            }
            Divider()
            ControlPanel(session: session)
            StatusBar(session: session)
        }
        .frame(minWidth: 900, minHeight: 560)
        .navigationTitle("SSCOM")
        .navigationSubtitle(session.isOpen ? session.linkDescription : "")
        .background(WindowLevelSetter(floating: session.settings.alwaysOnTop))
        .alert(item: $session.alert) { a in
            Alert(title: Text(a.title), message: Text(a.message))
        }
    }
}

/// Keeps the hosting window above others when "Always on top" is ticked.
private struct WindowLevelSetter: NSViewRepresentable {
    let floating: Bool
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        Task { @MainActor in view.window?.level = floating ? .floating : .normal }
    }
}

struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                section(HelpText.general)
                section(HelpText.checksum)
                section(HelpText.presets)
                section(HelpText.stm32)
                section(HelpText.stc)
            }
            .padding(20)
            .frame(maxWidth: 680, alignment: .leading)
        }
        .frame(minWidth: 520, minHeight: 480)
    }

    private func section(_ text: String) -> some View {
        let parts = text.split(separator: "\n", maxSplits: 1)
        return VStack(alignment: .leading, spacing: 6) {
            Text(String(parts.first ?? "")).font(.title3.bold())
            Text(String(parts.count > 1 ? parts[1] : "")).textSelection(.enabled)
        }
    }
}
