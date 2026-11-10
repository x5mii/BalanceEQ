// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import EQCore

struct CalibrationPanel: View {
    @ObservedObject var model: AppModel
    let sampleRate: Double
    let bypassed: Bool
    let visible: Bool
    @State private var relative = true
    @State private var before = true
    @State private var after = true
    @State private var target = true
    @State private var browser = false
    @State private var linkOnly = false
    @State private var dragStart: EQBand?
    private let range: ClosedRange<Double> = -30...30
    private var custom: Bool { model.preset.calibration?.customTargetEnabled == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Button("Choose Headphones…") { linkOnly = false; browser = true }
                Button("Link Measurement…") { linkOnly = true; browser = true }
                Spacer()
                if model.preset.calibration != nil {
                    Picker("Target mode", selection: Binding(get: { custom }, set: { value in
                        model.preset.calibration?.customTargetEnabled = value
                        if value { relative = false }
                    })) { Text("Reference").tag(false); Text("Custom Target").tag(true) }
                    .pickerStyle(.segmented).frame(width: 235)
                    Toggle("Auto headroom", isOn: Binding(get: { model.preset.calibration?.automaticHeadroom == true }, set: model.setAutomaticHeadroom))
                        .controlSize(.small).help("Estimated preamp attenuation. Not a limiter. Editing preamp switches to manual.")
                }
            }
            if let curve = model.measurement, let profile = model.measurementProfile,
               profile.id == model.preset.calibration?.measurementID {
                HStack {
                    Text(profile.name).font(.callout.weight(.semibold)).lineLimit(1).help(profile.name)
                    Spacer()
                    Picker("Response view", selection: $relative) {
                        Text("Difference from target").tag(true)
                        Text("Response").tag(false)
                    }.labelsHidden().frame(width: 205)
                }
                if visible {
                let result = Result { try curve.response(preset: model.preset, sampleRate: sampleRate, bypassed: bypassed, relative: relative) }
                switch result {
                case .success(let response):
                    graph(response)
                case .failure(let error):
                    Text(error.localizedDescription).foregroundStyle(.secondary).frame(height: 190)
                }
                } else { Color.clear.frame(height: 190) }
                HStack(spacing: 18) {
                    Toggle("Before", isOn: $before).tint(.gray)
                    Toggle("Predicted After", isOn: $after).tint(.blue)
                    Toggle("Target", isOn: $target).tint(.green)
                    Spacer()
                    Link("Measurement source", destination: profile.sourceURL)
                }.toggleStyle(.checkbox).font(.caption)
                Text("\(profile.targetName) · Level-matched prediction; preamp attenuation excluded. Not a measurement of your pair.")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                if custom {
                    HStack {
                        Menu { Button("Bell") { model.addTargetBand() }; Button("Low shelf") { model.addTargetBand(.lowShelf) }; Button("High shelf") { model.addTargetBand(.highShelf) } } label: { Label("Add target band", systemImage: "plus") }
                            .disabled(model.preset.bands.count >= 32)
                        Button("Reset Target", action: model.resetTarget)
                        Text(relative ? "Switch to Response to drag target points." : "Drag target points; edit exact frequency, gain and Q below.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                    }
                }
            } else {
                ContentUnavailableView("Measurement not linked", systemImage: "headphones",
                    description: Text(model.measurementError ?? (model.preset.calibration == nil ? "Choose a calibrated profile, or explicitly link the exact model to your existing EQ. EQ settings alone cannot reveal a headphone’s response." : "Loading the selected measurement…")))
                    .frame(height: 190)
            }
        }
        .task(id: (visible ? "visible" : "hidden") + (model.preset.calibration?.measurementID ?? "") + (model.preset.calibration?.sourceCommit ?? "")) { if visible { await model.loadMeasurement() } }
        .sheet(isPresented: $browser) { CalibrationBrowser(model: model, linkOnly: linkOnly) }
    }

    private func graph(_ response: CalibrationCurve.Response) -> some View {
        let maximum = response.frequencies.last ?? 20000
        return EQPlot(target: target ? response.target : [], before: before ? response.before : [],
                      after: after ? response.after : [], range: range, muted: bypassed)
            .padding(.leading, 40).padding(.trailing, 20).padding(.top, 32).padding(.bottom, 26)
            .background(PlotGrid(range: range, maximum: maximum).equatable())
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
            .overlay(alignment: .topLeading) {
                Text(relative ? "DEVIATION · 0 dB = TARGET" : "PUBLISHED RESPONSE · RELATIVE dB")
                    .font(.system(size: 9, weight: .medium)).tracking(1).foregroundStyle(.secondary).padding(12)
            }
            .overlay {
                if custom && !relative && target {
                    targetHandles(response, maximum: maximum)
                }
            }
            .frame(height: 190)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Predicted headphone response. \(relative ? "Zero decibels is the target." : "Published measurement reference.")")
    }

    private func targetHandles(_ response: CalibrationCurve.Response, maximum: Double) -> some View {
        let ids = Set(model.preset.calibration?.customBandIDs ?? [])
        let bands = model.preset.bands.filter { ids.contains($0.id) && $0.frequency >= 20 && $0.frequency <= maximum }
        return GeometryReader { geometry in
            ForEach(bands) { band in
                targetHandle(band, response: response, maximum: maximum, size: geometry.size)
            }
        }.coordinateSpace(name: "calibrationGraph")
    }

    private func targetHandle(_ band: EQBand, response: CalibrationCurve.Response, maximum: Double, size: CGSize) -> some View {
        let width = max(1, Double(size.width) - 60)
        let height = max(1, Double(size.height) - 58)
        let fraction = log(band.frequency / 20) / log(maximum / 20)
        let index = min(384, max(0, Int((fraction * 384).rounded())))
        let level = max(range.lowerBound, min(range.upperBound, response.target[index]))
        let position = CGPoint(x: 40 + fraction * width, y: 32 + (range.upperBound - level) / 60 * height)
        return Button { model.selectedBandID = band.id } label: {
            Circle().fill(band.enabled ? Color.green : Color.gray)
                .overlay(Circle().stroke(.background, lineWidth: model.selectedBandID == band.id ? 3 : 1))
                .frame(width: 14, height: 14).padding(7).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .position(position)
            .highPriorityGesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("calibrationGraph")).onChanged { gesture in
                if dragStart == nil { dragStart = band; model.selectedBandID = band.id }
                guard let start = dragStart, let i = model.preset.bands.firstIndex(where: { $0.id == start.id }) else { return }
                var value = model.preset
                value.bands[i].frequency = max(20, min(maximum, start.frequency * pow(maximum / 20, gesture.translation.width / width)))
                value.bands[i].gainDB = max(-24, min(24, start.gainDB - gesture.translation.height / height * 60))
                model.preset = value
            }.onEnded { _ in dragStart = nil })
            .accessibilityElement().accessibilityLabel("Target \(band.type.title), \(Int(band.frequency)) hertz")
            .accessibilityValue("\(band.gainDB.formatted()) decibels")
            .accessibilityAction { model.selectedBandID = band.id }
            .accessibilityAdjustableAction { direction in
                guard let i = model.preset.bands.firstIndex(where: { $0.id == band.id }) else { return }
                model.preset.bands[i].gainDB = max(-24, min(24, band.gainDB + (direction == .increment ? 0.1 : -0.1)))
            }
    }

}
