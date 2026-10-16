// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct SpectrumGraph: View {
    @ObservedObject var model: SpectrumModel
    let running: Bool

    var body: some View {
        let frame = model.frame
        let maximum = min(20_000, frame.sampleRate * 0.49)
        EQPlot(before: Self.displayBins(frame.before, sampleRate: frame.sampleRate),
               after: Self.displayBins(frame.after, sampleRate: frame.sampleRate),
               range: -100...0, spectrum: true)
            .padding(.leading, 40).padding(.trailing, 20).padding(.top, 32).padding(.bottom, 26)
            .background(PlotGrid(range: -100...0, maximum: maximum).equatable())
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
            .overlay(alignment: .topLeading) {
                HStack(spacing: 16) {
                    Label("Before", systemImage: "waveform").foregroundStyle(.secondary)
                    Label("After EQ", systemImage: "waveform").foregroundStyle(.blue)
                    Text("dBFS").foregroundStyle(.tertiary)
                }.font(.system(size: 10, weight: .medium)).padding(.horizontal, 16).padding(.top, 10)
            }
            .overlay {
                if !running || frame.before.isEmpty {
                    Text(running ? "Waiting for audio…" : "Start EQ to view live audio")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Live audio spectrum before and after EQ")
            .accessibilityValue(running && !frame.before.isEmpty ? "Before peak \(Int(frame.before.max() ?? -100)) dBFS. After peak \(Int(frame.after.max() ?? -100)) dBFS. Digital signal, not a headphone measurement." : "No live spectrum")
    }

    /// Peak-preserving logarithmic buckets keep the plot small without hiding narrow peaks.
    static func displayBins(_ values: [Double], sampleRate: Double) -> [Double] {
        guard values.count > 1 else { return [] }
        let count = 128
        let maximum = min(20_000, sampleRate * 0.49)
        let resolution = sampleRate / Double(AudioSpectrum.count)
        return (0..<count).map { i in
            let lower = 20 * pow(maximum / 20, max(0, Double(i) - 0.5) / Double(count - 1))
            let upper = 20 * pow(maximum / 20, min(Double(count - 1), Double(i) + 0.5) / Double(count - 1))
            let first = min(values.count - 1, max(1, Int((lower / resolution).rounded())))
            let last = min(values.count - 1, max(first, Int((upper / resolution).rounded())))
            return values[first...last].max() ?? -100
        }
    }
}
