// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import EQCore

struct CalibrationPanel: View {
    @ObservedObject var model: AppModel
    let sampleRate: Double
    let bypassed: Bool
    let visible: Bool
    @State private var before = false
    @State private var browser = false
    @State private var selected: CalibrationProfile?
    @State private var mode: CalibrationTargetMode = .neutral
    @State private var customBase: CalibrationTargetMode = .neutral
    @State private var busy = false
    @State private var error: String?
    @State private var targets: CalibrationTargets?
    private let range: ClosedRange<Double> = -24...24
    private var baseMode: CalibrationTargetMode { mode == .custom ? customBase : mode }
    private var selectedTarget: CalibrationTarget? { selected.flatMap { targets?.target(for: $0, mode: baseMode) } }
    private var applied: Bool {
        selected?.id == model.preset.calibration?.measurementID && mode == model.preset.calibration?.targetMode &&
        (mode != .custom || customBase == model.preset.calibration?.customBase)
    }
    private var editingCustom: Bool { applied && mode == .custom }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("1  HEADPHONES").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Button { browser = true } label: {
                        Label(selected?.name ?? "Choose Headphones…", systemImage: "headphones").lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.controlSize(.large).help(selected?.name ?? "Choose the exact model and pad variant")
                }.frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 6) {
                    Text("2  TARGET").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Picker("Calibration target", selection: $mode) {
                        Text("Neutral").tag(CalibrationTargetMode.neutral)
                        Text("Harman").tag(CalibrationTargetMode.harman)
                            .disabled(selected.map { targets?.target(for: $0, mode: .harman) == nil } ?? true)
                        Text("Custom").tag(CalibrationTargetMode.custom)
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 260)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("3  APPLY").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Button(busy ? "Applying…" : "Apply Correction", action: apply)
                        .buttonStyle(.borderedProminent).controlSize(.large).disabled(selectedTarget == nil || busy)
                }
            }.disabled(busy)
            HStack {
                Text(mode == .harman ? "Harman preference tuning, matched to this measurement." : mode == .custom ? "Shape your own target from a compatible reference." : "Neutral uses the matched reference without the added bass shelf.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                if mode == .custom {
                    Picker("Custom target base", selection: $customBase) {
                        Text("Neutral base").tag(CalibrationTargetMode.neutral)
                        Text("Harman base").tag(CalibrationTargetMode.harman)
                            .disabled(selected.map { targets?.target(for: $0, mode: .harman) == nil } ?? true)
                    }.labelsHidden().frame(width: 160).disabled(busy)
                }
            }
            if selected != nil && selectedTarget == nil {
                Text("No compatible \(baseMode.title) target is published for this measurement. Choose another measured variant or use Advanced EQ.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            if let curve = model.measurement, let profile = model.measurementProfile,
               profile.id == model.preset.calibration?.measurementID {
                HStack {
                    Label(bypassed ? "Bypassed · original sound" : (model.preset.calibration?.targetMode.map { "\($0.title) correction applied" } ?? "Existing correction"), systemImage: bypassed ? "pause.circle" : "checkmark.circle")
                        .font(.callout.weight(.medium))
                    Text(profile.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    if !applied { Text("Selection not applied").font(.caption).foregroundStyle(.orange) }
                }
                if visible {
                    let result = Result { try curve.result(preset: model.preset, profile: profile, sampleRate: sampleRate, bypassed: bypassed) }
                    switch result {
                    case .success(let response): graph(response, neutral: targets?.target(for: profile, mode: .neutral) != nil)
                    case .failure(let error): Text(error.localizedDescription).foregroundStyle(.secondary).frame(height: 240)
                    }
                } else { Color.clear.frame(height: 240) }
                HStack(spacing: 18) {
                    Label("Predicted result", systemImage: "line.diagonal").foregroundStyle(.blue)
                    Label("Chosen target", systemImage: "line.diagonal").foregroundStyle(.green)
                    Toggle("Show before", isOn: $before).toggleStyle(.checkbox)
                    Spacer()
                    Toggle("Auto headroom", isOn: Binding(get: { model.preset.calibration?.automaticHeadroom == true }, set: model.setAutomaticHeadroom))
                        .toggleStyle(.checkbox).help("Estimated preamp attenuation; not a limiter.")
                }.font(.caption)
                Text("Blue should follow green. This predicts the model’s tonal response, not a measurement of your pair. Preamp attenuation is excluded.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text(referenceName(profile: profile)).lineLimit(2)
                    Spacer()
                    Link("Measurement source", destination: profile.sourceURL)
                }.font(.caption2).foregroundStyle(.secondary)
                if editingCustom { customControls }
            } else {
                ContentUnavailableView(model.preset.calibration == nil ? "Choose your headphones to begin" : "Loading headphone response…", systemImage: "headphones",
                    description: Text(model.measurementError ?? "Select a model and target, then Apply Correction. Your current EQ stays unchanged until you apply."))
                    .frame(height: 240)
            }
        }
        .task(id: (visible ? "visible" : "hidden") + (model.preset.calibration?.measurementID ?? "") + (model.preset.calibration?.sourceCommit ?? "")) {
            guard visible else { return }
            do { targets = try CalibrationTargets.bundled(); try await model.loadCalibrationCatalog(); if selected == nil { restoreSelection() } }
            catch { self.error = error.localizedDescription }
            await model.loadMeasurement()
        }
        .onChange(of: model.preset.id) { _, _ in restoreSelection() }
        .sheet(isPresented: $browser) {
            CalibrationBrowser(model: model, onSelect: { profile in selected = profile; error = nil })
        }
    }

    private func restoreSelection() {
        selected = model.calibrationProfiles.first { $0.id == model.preset.calibration?.measurementID }
        mode = model.preset.calibration?.targetMode ?? .neutral
        customBase = model.preset.calibration?.customBase ?? .neutral
    }
    private func apply() {
        guard let selected, !busy else { return }
        busy = true; error = nil
        Task {
            defer { busy = false }
            do { try await model.applyCalibration(selected, mode: mode, customBase: customBase) }
            catch { self.error = error.localizedDescription }
        }
    }
    private func referenceName(profile: CalibrationProfile) -> String {
        guard let id = model.preset.calibration?.targetID, let target = try? targets?.target(id: id) else { return profile.targetName }
        let bass = model.preset.calibration?.customBase == .harman
        return "Reference: \(target.name) · \(bass ? "AutoEq preference bass" : "no added bass shelf") · \(profile.source) / \(profile.variant)"
    }
    private func graph(_ response: CalibrationCurve.Response, neutral: Bool) -> some View {
        let maximum = response.frequencies.last ?? 20000
        return EQPlot(target: response.target, before: before ? response.before : [], after: response.after, range: range, muted: bypassed)
            .padding(.leading, 40).padding(.trailing, 20).padding(.top, 32).padding(.bottom, 26)
            .background(PlotGrid(range: range, maximum: maximum).equatable())
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
            .overlay(alignment: .topLeading) {
                Text(neutral ? "PREDICTED SOUND · NEUTRAL REFERENCE = 0 dB" : "PREDICTED SOUND · PUBLISHED REFERENCE = 0 dB")
                    .font(.system(size: 9, weight: .medium)).tracking(1).foregroundStyle(.secondary).padding(12)
            }
            .overlay { if editingCustom { targetHandles(response, maximum: maximum) } }
            .frame(height: 240)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Predicted headphone result and chosen target. Blue should follow green.")
    }
    private var customControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Menu { Button("Bell") { model.addTargetBand() }; Button("Low shelf") { model.addTargetBand(.lowShelf) }; Button("High shelf") { model.addTargetBand(.highShelf) } } label: { Label("Add target point", systemImage: "plus") }
                    .disabled(model.preset.bands.count >= 32)
                Button("Reset Custom", action: model.resetTarget)
                Text("Drag green points to tune; scroll a point to adjust Q. Custom edits apply live.").font(.caption).foregroundStyle(.secondary)
            }
            if let index = customIndex {
                HStack(spacing: 12) {
                    Text("Target point").font(.caption)
                    DecimalField(label: "Target frequency", value: $model.preset.bands[index].frequency, range: 20...min(20000,sampleRate * 0.49)).frame(width: 85)
                    Text("Hz")
                    DecimalField(label: "Target gain", value: $model.preset.bands[index].gainDB, range: -24...24).frame(width: 65)
                    Text("dB   Q")
                    DecimalField(label: "Target Q", value: $model.preset.bands[index].q, range: 0.1...30).frame(width: 65)
                    Toggle("Enabled", isOn: $model.preset.bands[index].enabled).toggleStyle(.checkbox)
                    Button("Remove point") { model.selectedBandID = model.preset.bands[index].id; model.removeSelectedBand() }
                    Spacer()
                }.textFieldStyle(.roundedBorder).font(.caption)
            }
        }
    }
    private var customIndex: Int? {
        let ids = Set(model.preset.calibration?.customBandIDs ?? [])
        return model.preset.bands.firstIndex { ids.contains($0.id) && $0.id == model.selectedBandID }
            ?? model.preset.bands.firstIndex { ids.contains($0.id) }
    }
    private func targetHandles(_ response: CalibrationCurve.Response, maximum: Double) -> some View {
        let ids = Set(model.preset.calibration?.customBandIDs ?? [])
        let bands = model.preset.frequencyOrderedBands.filter { ids.contains($0.id) && $0.frequency >= 20 && $0.frequency <= maximum }
        return GeometryReader { geometry in
            ForEach(bands) { band in
                let width = max(1, geometry.size.width - 60), height = max(1, geometry.size.height - 58)
                let fraction = log(band.frequency / 20) / log(maximum / 20)
                let index = min(384, max(0, Int((fraction * 384).rounded())))
                let level = max(range.lowerBound, min(range.upperBound, response.target[index]))
                GraphBandPoint(band: band, selected: model.selectedBandID == band.id, color: .systemGreen,
                               maximum: maximum, plotSize: CGSize(width: width, height: height), gainSpan: 48,
                               select: { model.selectedBandID = band.id }, change: { value in
                    guard let index = model.preset.bands.firstIndex(where: { $0.id == band.id }) else { return }
                    model.preset.bands[index] = value
                }).frame(width: 28, height: 28)
                    .position(x: 40 + fraction * width, y: 32 + (range.upperBound - level) / 48 * height)
                    .zIndex(model.selectedBandID == band.id ? 1 : 0)
            }
        }
    }
}
