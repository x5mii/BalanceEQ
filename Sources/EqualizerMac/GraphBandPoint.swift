// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SwiftUI
import EQCore

/// Shared native tracking for correction and custom-target points. Events stay off the audio thread.
struct GraphBandPoint: NSViewRepresentable {
    let band: EQBand
    let selected: Bool
    let color: NSColor
    let maximum: Double
    let plotSize: CGSize
    let gainSpan: Double
    let select: () -> Void
    let change: (EQBand) -> Void

    func makeNSView(context: Context) -> PointButton { PointButton() }
    func updateNSView(_ view: PointButton, context: Context) {
        view.band = band
        view.selected = selected
        view.color = color
        view.maximum = maximum
        view.plotSize = plotSize
        view.gainSpan = gainSpan
        view.select = select
        view.change = change
        view.needsDisplay = true
        view.setAccessibilityLabel("\(band.type.title), \(Int(band.frequency)) hertz")
        view.setAccessibilityValue(String(format: "Gain %.1f decibels, Q %.2f", band.gainDB, band.q))
        view.setAccessibilityHelp("Drag to change frequency and gain. Scroll up to narrow Q, down to widen. Arrow keys change frequency and gain; Option-up or Option-down changes Q.")
        view.toolTip = String(format: "%.0f Hz · %+.1f dB · Q %.2f\nDrag to tune. Scroll up: narrower; down: wider.", band.frequency, band.gainDB, band.q)
    }

    static func dragged(_ band: EQBand, translation: CGSize, size: CGSize, maximum: Double, gainSpan: Double) -> EQBand {
        var result = band
        result.frequency = max(10, min(maximum, band.frequency * pow(maximum / 20, translation.width / max(1, size.width))))
        if [.peak, .lowShelf, .highShelf].contains(band.type) {
            result.gainDB = max(-24, min(24, band.gainDB - translation.height / max(1, size.height) * gainSpan))
        }
        return result
    }

    static func scrolledQ(_ q: Double, delta: Double, precise: Bool) -> Double {
        guard delta.isFinite else { return q }
        return max(0.1, min(30, q * pow(2, max(-12, min(12, delta * (precise ? 0.008 : 0.12))))))
    }

    final class PointButton: NSButton {
        var band = EQBand()
        var selected = false
        var color = NSColor.systemBlue
        var maximum = 20000.0
        var plotSize = CGSize(width: 1, height: 1)
        var gainSpan = 48.0
        var select: () -> Void = {}
        var change: (EQBand) -> Void = { _ in }
        private var start: (band: EQBand, point: CGPoint)?

        init() {
            super.init(frame: .zero)
            title = ""
            isBordered = false
            target = self
            action = #selector(activate)
        }
        required init?(coder: NSCoder) { nil }
        override var acceptsFirstResponder: Bool { true }
        @objc private func activate() { window?.makeFirstResponder(self); select() }

        override func draw(_ dirtyRect: NSRect) {
            let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 7, dy: 7))
            (band.enabled ? color : NSColor.secondaryLabelColor).setFill()
            circle.fill()
            NSColor.controlBackgroundColor.setStroke()
            circle.lineWidth = selected ? 3 : 1
            circle.stroke()
            if window?.firstResponder === self {
                NSColor.keyboardFocusIndicatorColor.setStroke()
                let focus = NSBezierPath(ovalIn: bounds.insetBy(dx: 3, dy: 3))
                focus.lineWidth = 2
                focus.stroke()
            }
        }
        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            start = (band, event.locationInWindow)
            select()
        }
        override func mouseDragged(with event: NSEvent) {
            guard let start else { return }
            let translation = CGSize(width: event.locationInWindow.x - start.point.x, height: start.point.y - event.locationInWindow.y)
            change(GraphBandPoint.dragged(start.band, translation: translation, size: plotSize, maximum: maximum, gainSpan: gainSpan))
        }
        override func mouseUp(with event: NSEvent) { start = nil }
        override func scrollWheel(with event: NSEvent) {
            // Momentum must not continue changing a tuning after the user stops scrolling.
            guard event.momentumPhase.isEmpty else { return }
            select()
            var value = band
            let delta = event.scrollingDeltaY * (event.isDirectionInvertedFromDevice ? -1 : 1)
            value.q = GraphBandPoint.scrolledQ(band.q, delta: delta, precise: event.hasPreciseScrollingDeltas)
            change(value)
        }
        override func keyDown(with event: NSEvent) {
            guard [123,124,125,126].contains(event.keyCode) else { super.keyDown(with: event); return }
            select()
            var value = band
            if event.modifierFlags.contains(.option), [125,126].contains(event.keyCode) {
                value.q = GraphBandPoint.scrolledQ(band.q, delta: event.keyCode == 126 ? 1 : -1, precise: false)
            } else if [123,124].contains(event.keyCode) {
                value.frequency = max(10, min(maximum, band.frequency * pow(2, event.keyCode == 124 ? 1.0/24 : -1.0/24)))
            } else if [.peak, .lowShelf, .highShelf].contains(band.type) {
                value.gainDB = max(-24, min(24, band.gainDB + (event.keyCode == 126 ? 0.1 : -0.1)))
            }
            change(value)
        }
    }
}

#if DEBUG
extension GraphBandPoint {
    static func check() {
        let band = EQBand(frequency: 1000, gainDB: 2, q: 0.2)
        let moved = dragged(band, translation: CGSize(width: 100, height: -10), size: CGSize(width: 1000, height: 100), maximum: 20000, gainSpan: 48)
        precondition(abs(moved.frequency - 1995.2623149688795) < 0.0001 && abs(moved.gainDB - 6.8) < 0.0001)
        precondition(moved.q == band.q)
        precondition(scrolledQ(0.2, delta: 1, precise: false) > 0.2)
        precondition(abs(scrolledQ(scrolledQ(0.2, delta: 1, precise: false), delta: -1, precise: false) - 0.2) < 1e-12)
        precondition(scrolledQ(30, delta: 1000, precise: false) == 30 && scrolledQ(0.1, delta: -1000, precise: true) == 0.1)
        precondition(scrolledQ(1, delta: .nan, precise: false) == 1)
        let pass = EQBand(type: .lowPass, frequency: 1000)
        precondition(dragged(pass, translation: CGSize(width: 99999, height: -99999), size: .zero, maximum: 3999, gainSpan: 48).gainDB == 0)
        let edge = dragged(band, translation: CGSize(width: 99999, height: -99999), size: CGSize(width: 1000, height: 100), maximum: 3999, gainSpan: 48)
        precondition(edge.frequency == 3999 && edge.gainDB == 24)
    }
}
#endif
