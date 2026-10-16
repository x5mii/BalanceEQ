// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct SpectrumGraph: View {
    let spectrum: Spectrum
    let running: Bool

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(x: 40, y: 29, width: max(1, size.width - 62), height: max(1, size.height - 56))
            let maximum = min(20_000, spectrum.sampleRate * 0.49)
            func x(_ frequency: Double) -> Double { rect.minX + log(frequency / 20) / log(maximum / 20) * rect.width }
            func y(_ db: Double) -> Double { rect.maxY - max(0, min(100, db + 100)) / 100 * rect.height }
            for db in [-100.0, -75, -50, -25, 0] {
                var line = Path()
                line.move(to: CGPoint(x: rect.minX, y: y(db)))
                line.addLine(to: CGPoint(x: rect.maxX, y: y(db)))
                context.stroke(line, with: .color(.primary.opacity(0.08)))
                context.draw(Text("\(Int(db))").font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary), at: CGPoint(x: 21, y: y(db)))
            }
            for frequency in [20.0, 100, 1000, 10000, 20000] where frequency <= maximum {
                let label = frequency >= 1000 ? "\(Int(frequency / 1000))k" : "\(Int(frequency))"
                context.draw(Text(label).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary), at: CGPoint(x: x(frequency), y: rect.maxY + 16))
            }
            for (index, values) in [spectrum.before, spectrum.after].enumerated() {
                var curve = Path()
                for bin in 1..<max(1, values.count) {
                    let frequency = Double(bin) * spectrum.sampleRate / Double(AudioSpectrum.count)
                    guard frequency >= 20, frequency <= maximum else { continue }
                    let point = CGPoint(x: x(frequency), y: y(values[bin]))
                    if curve.isEmpty { curve.move(to: point) } else { curve.addLine(to: point) }
                }
                context.stroke(curve, with: .color(index == 0 ? .secondary : .blue), style: StrokeStyle(lineWidth: index == 0 ? 1.5 : 2, dash: index == 0 ? [4, 3] : []))
            }
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
        .overlay(alignment: .topLeading) {
            Text("– – BEFORE    ━ AFTER EQ · STEREO POWER AVERAGE")
                .font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary).padding(12)
        }
        .overlay {
            if !running || spectrum.before.isEmpty {
                Text(running ? "Waiting for audio…" : "Start EQ to view live audio")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Live audio spectrum before and after EQ")
        .accessibilityValue(running && !spectrum.before.isEmpty ? "Before peak \(Int(spectrum.before.max() ?? -100)) dBFS. After peak \(Int(spectrum.after.max() ?? -100)) dBFS. Digital signal, not a headphone measurement." : "No live spectrum")
    }
}
