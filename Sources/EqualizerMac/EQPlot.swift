// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SwiftUI
import QuartzCore

/// Core Animation interpolates fixed-topology paths; SwiftUI doesn't redraw at display rate.
struct EQPlot: NSViewRepresentable {
    var before: [Double] = []
    let after: [Double]
    let range: ClosedRange<Double>
    var muted = false
    var spectrum = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> PlotView { PlotView() }
    func updateNSView(_ view: PlotView, context: Context) {
        view.update(before: before, after: after, range: range, muted: muted,
                    spectrum: spectrum, reduceMotion: reduceMotion)
    }
    static func dismantleNSView(_ view: PlotView, coordinator: ()) { view.stopAnimations() }

    final class PlotView: NSView {
        private let inputLine = CAShapeLayer()
        private let outputLine = CAShapeLayer()
        private let fill = CAShapeLayer()
        private let gradient = CAGradientLayer()
        private var before: [Double] = []
        private var after: [Double] = []
        private var range: ClosedRange<Double> = -100...0
        private var muted = false
        private var plottedSize = CGSize.zero
        private var spectrum = false
        override var isFlipped: Bool { true }

        init() {
            super.init(frame: .zero)
            wantsLayer = true
            layer?.masksToBounds = true
            gradient.mask = fill
            gradient.startPoint = CGPoint(x: 0.5, y: 0)
            gradient.endPoint = CGPoint(x: 0.5, y: 1)
            layer?.addSublayer(gradient)
            for line in [inputLine, outputLine] {
                line.fillColor = nil
                line.lineCap = .round
                line.lineJoin = .round
                layer?.addSublayer(line)
            }
            inputLine.lineWidth = 1.25
            inputLine.lineDashPattern = [4, 4]
            outputLine.lineWidth = 2.25
            colors()
        }
        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func update(before: [Double], after: [Double], range: ClosedRange<Double>, muted: Bool,
                    spectrum: Bool, reduceMotion: Bool) {
            let reset = self.range != range || self.spectrum != spectrum
            self.range = range
            let styleChanged = self.muted != muted
            self.muted = muted
            self.spectrum = spectrum
            self.before = before
            self.after = after
            if styleChanged { colors() }
            drawPaths(animated: !reset && !reduceMotion && window?.occlusionState.contains(.visible) == true)
        }

        override func layout() {
            super.layout()
            guard plottedSize != bounds.size else { return }
            plottedSize = bounds.size
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for child in [gradient, inputLine, outputLine, fill] { child.frame = bounds }
            CATransaction.commit()
            drawPaths(animated: false)
        }
        override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); colors() }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window == nil { stopAnimations() } }

        private func colors() {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                let color = muted ? NSColor.secondaryLabelColor : NSColor.systemBlue
                outputLine.strokeColor = color.cgColor
                inputLine.strokeColor = NSColor.secondaryLabelColor.withAlphaComponent(0.65).cgColor
                gradient.colors = [color.withAlphaComponent(0.24).cgColor, color.withAlphaComponent(0.015).cgColor]
                CATransaction.commit()
            }
        }

        private func drawPaths(animated: Bool) {
            guard bounds.width > 0, bounds.height > 0 else { return }
            let input = Self.path(before, in: bounds.size, range: range)
            let output = Self.path(after, in: bounds.size, range: range)
            let area = output.mutableCopy()!
            if !after.isEmpty {
                area.addLine(to: CGPoint(x: bounds.width, y: bounds.height))
                area.addLine(to: CGPoint(x: 0, y: bounds.height))
                area.closeSubpath()
            }
            for (line, path) in [(inputLine, input), (outputLine, output), (fill, area as CGPath)] {
                let previous = line.presentation()?.path ?? line.path
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                line.path = path
                CATransaction.commit()
                line.removeAnimation(forKey: "curve")
                if animated, let previous, !previous.isEmpty, !path.isEmpty {
                    let animation = CABasicAnimation(keyPath: "path")
                    animation.fromValue = previous
                    animation.toValue = path
                    animation.duration = spectrum ? 0.10 : 0.12
                    animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    line.add(animation, forKey: "curve")
                }
            }
        }

        func stopAnimations() { for shape in [inputLine, outputLine, fill] { shape.removeAllAnimations() } }

        static func path(_ values: [Double], in size: CGSize, range: ClosedRange<Double>) -> CGPath {
            let path = CGMutablePath()
            guard values.count > 1 else { return path }
            func point(_ i: Int) -> CGPoint {
                let value = values[i].isFinite ? values[i] : range.lowerBound
                let normalized = max(0, min(1, (value - range.lowerBound) / (range.upperBound - range.lowerBound)))
                return CGPoint(x: Double(i) / Double(values.count - 1) * size.width, y: (1 - normalized) * size.height)
            }
            var previous = point(0)
            path.move(to: previous)
            for i in 1..<values.count {
                let next = point(i)
                let middleX = (previous.x + next.x) / 2
                path.addCurve(to: next, control1: CGPoint(x: middleX, y: previous.y), control2: CGPoint(x: middleX, y: next.y))
                previous = next
            }
            return path
        }
    }
}

/// Static chrome is separate from the animated paths and stays out of spectrum updates.
struct PlotGrid: View, Equatable {
    let range: ClosedRange<Double>
    let maximum: Double
    var body: some View {
        Canvas { context, size in
            let rect = CGRect(x: 40, y: 32, width: max(1, size.width - 60), height: max(1, size.height - 58))
            for i in 0...4 {
                let db = range.lowerBound + Double(i) / 4 * (range.upperBound - range.lowerBound)
                let y = rect.maxY - Double(i) / 4 * rect.height
                var line = Path(); line.move(to: CGPoint(x: rect.minX, y: y)); line.addLine(to: CGPoint(x: rect.maxX, y: y))
                context.stroke(line, with: .color(.primary.opacity(db == 0 ? 0.14 : 0.055)))
                context.draw(Text(String(format: "%.0f", db)).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary), at: CGPoint(x: 20, y: y))
            }
            for frequency in [20.0, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000] where frequency <= maximum {
                let x = rect.minX + log(frequency / 20) / log(maximum / 20) * rect.width
                var line = Path(); line.move(to: CGPoint(x: x, y: rect.minY)); line.addLine(to: CGPoint(x: x, y: rect.maxY))
                context.stroke(line, with: .color(.primary.opacity(0.035)))
                let label = frequency >= 1000 ? "\(Int(frequency / 1000))k" : "\(Int(frequency))"
                context.draw(Text(label).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary), at: CGPoint(x: x, y: rect.maxY + 16))
            }
        }
    }
}

#if DEBUG
extension EQPlot {
    static func check() {
        // Interpolate to the final target in Core Animation, rather than advancing an IIR
        // only when SwiftUI sees changed values: identical silence frames must settle fully.
        let silence = PlotView.path([-100, -100], in: CGSize(width: 200, height: 100), range: -100...0)
        precondition(silence.boundingBoxOfPath.minY == 100 && silence.boundingBoxOfPath.maxY == 100)
        let path = PlotView.path([-.infinity, -50, 100], in: CGSize(width: 200, height: 100), range: -100...0)
        precondition(path.boundingBoxOfPath.minY >= 0 && path.boundingBoxOfPath.maxY <= 100)
        var bins = [Double](repeating: -100, count: AudioSpectrum.count / 2)
        bins[100] = -10
        let reduced = SpectrumGraph.displayBins(bins, sampleRate: 48000)
        precondition(reduced.count == 128 && reduced.max() == -10, "Display reduction must retain peaks")
        precondition(SpectrumGraph.displayBins([], sampleRate: 48000).isEmpty)
    }
}
#endif
