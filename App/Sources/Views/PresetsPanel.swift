import SwiftUI
import SSCOMKit

/// SSCOM's "multi-string send" panel: 99 strings, each with HEX flag, note, loop order and delay.
struct PresetsPanel: View {
    @Bindable var session: Session
    @State private var editingNote: Int?
    @State private var noteDraft = ""
    @State private var showHelp = false
    @State private var pendingSet: PresetSet?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Toggle("Loop send", isOn: $session.presetLoopEnabled)
                    .disabled(!session.isOpen)
                    .help("Send strings with an order above 0, lowest first, waiting each string's delay")
                Spacer()
                Menu("Presets") {
                    ForEach(PresetLibrary.all) { set in
                        Button(set.name) { pendingSet = set }
                    }
                    Divider()
                    Button("SSCOM Defaults") { session.settings.presets = PresetString.defaults() }
                }
                .fixedSize()
                .help("Replace the strings with a ready-made set")
                .accessibilityIdentifier("presets.library")
                Button("Import ini…") { session.importLegacyIni() }
                    .help("Import strings and settings from an SSCOM sscom51.ini file")
                Button {
                    showHelp = true
                } label: {
                    Image(systemName: "questionmark.circle")
                }
                .buttonStyle(.borderless)
                .popover(isPresented: $showHelp) {
                    ScrollView { Text(HelpText.presets).padding().textSelection(.enabled) }
                        .frame(width: 420, height: 320)
                }
            }
            .padding(8)
            Divider()
            List {
                Section {
                    ForEach($session.settings.presets) { $preset in
                        row($preset)
                            .listRowInsets(EdgeInsets(top: 1, leading: 4, bottom: 1, trailing: 4))
                    }
                } header: {
                    columnHeader
                }
            }
            .listStyle(.plain)
        }
        .controlSize(.small)
        .frame(minWidth: 360, idealWidth: 420)
        .confirmationDialog(pendingSet?.name ?? "", isPresented: Binding(get: { pendingSet != nil },
                                                                          set: { if !$0 { pendingSet = nil } })) {
            Button("Replace Strings") {
                if let set = pendingSet {
                    session.settings.load(set, connected: session.isOpen)
                    session.systemMessage(String(localized: "Loaded \(set.name). Checksum: \(set.checksum.displayName)."))
                }
                pendingSet = nil
            }
        } message: {
            Text("Your current 99 strings are replaced. \(pendingSet?.summary ?? "")")
        }
        .alert("Note for string \(editingNote ?? 0)", isPresented: Binding(get: { editingNote != nil },
                                                                          set: { if !$0 { editingNote = nil } })) {
            TextField("Note", text: $noteDraft)
            Button("OK") {
                if let id = editingNote, let i = session.settings.presets.firstIndex(where: { $0.id == id }) {
                    session.settings.presets[i].note = noteDraft
                }
                editingNote = nil
            }
            Button("Cancel", role: .cancel) { editingNote = nil }
        } message: {
            Text("The note is shown on the send button.")
        }
    }

    /// Column widths shared by the heading and every row, so they line up.
    private enum Column {
        static let spacing: CGFloat = 6
        static let hex: CGFloat = 24
        static let send: CGFloat = 106
        static let order: CGFloat = 36
        static let delay: CGFloat = 52
    }

    private var columnHeader: some View {
        HStack(spacing: Column.spacing) {
            Text("HEX").frame(width: Column.hex)
            Text("String")
                .lineLimit(1)
                .help("Double-click a Send button to edit its note")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Send").frame(width: Column.send)
            Text("Order").frame(width: Column.order)
            Text("Delay ms").frame(width: Column.delay)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
    }

    private func row(_ preset: Binding<PresetString>) -> some View {
        let p = preset.wrappedValue
        let active = session.activePresetID == p.id && session.presetLoopEnabled
        return HStack(spacing: Column.spacing) {
            Toggle("HEX", isOn: preset.hex).labelsHidden().help("HEX string")
                .frame(width: Column.hex)
            TextField("String \(p.id)", text: preset.text)
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity)
            Button {
                Task { await session.sendPreset(p.id) }
            } label: {
                Text(p.note.isEmpty ? "\(p.id)" : p.note)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(active ? .red : .primary)
            }
            .buttonStyle(.bordered)
            // A visible outline so the button doesn't read as a label inside the list.
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(session.isOpen && !p.text.isEmpty ? 0.6 : 0.25), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .frame(width: Column.send)
            .disabled(!session.isOpen || p.text.isEmpty)
            .accessibilityIdentifier("preset.send.\(p.id)")
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                noteDraft = p.note
                editingNote = p.id
            })
            .contextMenu {
                Button("Edit Note…") { noteDraft = p.note; editingNote = p.id }
            }
            TextField("0", value: preset.order, format: .number.grouping(.never))
                .multilineTextAlignment(.center)
                .frame(width: Column.order)
                .help("Loop order (0 = skip)")
            TextField("1000", value: preset.delayMs, format: .number.grouping(.never))
                .multilineTextAlignment(.center)
                .frame(width: Column.delay)
        }
    }
}
