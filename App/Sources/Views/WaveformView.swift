import Charts
import SwiftUI

/// SSCOM's "data waveform (oscilloscope)": each received byte is one sample.
/// Shows 500 samples at a time; ‹500 and 500› page through history.
struct WaveformView: View {
    let session: Session
    @State private var signed = false
    @State private var live = true
    /// Samples back from the newest one at which the window ends.
    @State private var offsetFromEnd = 0
    @State private var samples: [Int] = []
    @State private var total = 0

    private let window = 500

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Button("‹ 500") { offsetFromEnd += window; live = false; refresh() }
                    .disabled(offsetFromEnd + window >= total)
                Button("500 ›") { offsetFromEnd = max(offsetFromEnd - window, 0); refresh() }
                    .disabled(offsetFromEnd == 0)
                Toggle("Live refresh", isOn: $live)
                    .help("Refresh once a second with the newest data")
                Toggle("Signed values", isOn: $signed)
                    .help("Show bytes as signed char (−128…127) instead of unsigned (0…255)")
                Spacer()
                Text("\(total) samples").foregroundStyle(.secondary).monospacedDigit()
                Button("Show") { offsetFromEnd = 0; refresh() }
            }
            .controlSize(.small)

            Chart {
                ForEach(Array(samples.enumerated()), id: \.offset) { i, v in
                    LineMark(x: .value("Sample", i), y: .value("Value", v))
                        .interpolationMethod(.linear)
                }
            }
            .chartYScale(domain: signed ? -128...127 : 0...255)
            .chartXScale(domain: 0...(window - 1))
            .chartXAxisLabel("Sample")
            .chartYAxisLabel("Value")
            .accessibilityLabel("Waveform of received bytes")

            Text("Single channel, 8-bit resolution, no protocol: every received byte is plotted as one sample.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(minWidth: 640, minHeight: 360)
        .onAppear(perform: refresh)
        .onChange(of: signed) { refresh() }
        .task(id: live) {
            while live, !Task.isCancelled {
                offsetFromEnd = 0
                refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func refresh() {
        let bytes = session.log.receivedBytes
        total = bytes.count
        let end = max(bytes.count - offsetFromEnd, 0)
        let start = max(end - window, 0)
        samples = bytes[start..<end].map { signed ? Int(Int8(bitPattern: $0)) : Int($0) }
    }
}
