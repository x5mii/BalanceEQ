import AppKit
import EQCore
import SwiftUI

struct EqualizerView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var audio: AudioController
    let appDelegate: AppDelegate
    @Environment(\.openWindow) private var openWindow
    @State private var showingSave = false
    @State private var showingPresets = false
    @State private var showingHeadphones = false
    @State private var showingCredits = false

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    controls
                    ResponseGraph(preset: model.preset, sampleRate: audio.sampleRate > 0 ? audio.sampleRate : 48000, bypassed: model.bypassed)
                        .equatable()
                        .frame(height: 174)
                    bandSection
                    inspector
                    footer
                }.padding(20)
            }
        }
        .frame(minWidth: 930, minHeight: 710)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(.teal)
        .onAppear { appDelegate.reopen = { openWindow(id: "equalizer") } }
        .alert("Equalizer for Mac", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("OK") { model.message = nil }
        } message: { Text(model.message ?? "") }
        .sheet(isPresented: $showingSave) { saveSheet }
        .sheet(isPresented: $showingPresets) { presetSheet }
        .sheet(isPresented: $showingHeadphones) { HeadphoneProfilesView(model: model) }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "waveform.path").font(.system(size: 27, weight: .medium)).foregroundStyle(.teal)
                .frame(width: 48, height: 48).background(.teal.opacity(0.1), in: RoundedRectangle(cornerRadius: 15))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Equalizer").font(.system(size: 25, weight: .semibold, design: .rounded))
                Text("Your Mac. Your sound.").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 7) {
                Circle().fill(audio.isRunning ? Color.teal : Color.secondary).frame(width: 7, height: 7)
                Text(audio.isStarting ? "STARTING" : (audio.isRunning ? (model.bypassed ? "BYPASSED" : "PROCESSING") : "READY"))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(1.2)
            }.padding(.horizontal, 12).padding(.vertical, 9).modifier(ControlSurface())
            Button(action: model.toggleProcessing) {
                Label(audio.isStarting ? "Starting…" : (audio.isRunning ? "Stop" : "Start EQ"), systemImage: audio.isRunning ? "stop.fill" : "play.fill")
                    .frame(minWidth: 78)
            }.buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(audio.isStarting)
                .help("Start or stop processing the normal system output")
        }.padding(.horizontal, 26).padding(.vertical, 14)
    }

    private var controls: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                sectionLabel("PRESET")
                Menu {
                    Button("Flat") { model.choose(.flat) }
                    Divider()
                    ForEach(model.presets) { preset in Button(preset.name) { model.choose(preset) } }
                    Divider()
                    Button("Save a Copy…") { showingSave = true }
                    Button("Manage Presets…") { showingPresets = true }
                    Button("Headphone Profiles…") { showingHeadphones = true }
                    Button("Import APO Preset…", action: model.importPreset)
                    Button("Export APO Preset…", action: model.exportPreset)
                } label: {
                    HStack { Image(systemName: "slider.horizontal.3"); Text(model.preset.name).lineLimit(1); Spacer() }
                        .frame(width: 190)
                }.frame(width: 230).controlSize(.large).accessibilityLabel("Preset: \(model.preset.name)")
            }
            VStack(alignment: .leading, spacing: 6) {
                sectionLabel("SYSTEM OUTPUT")
                Picker("System output", selection: Binding(get: { audio.selectedOutputID }, set: { audio.selectOutput($0) })) {
                    if audio.outputs.isEmpty { Text("No output available").tag(UInt32(0)) }
                    ForEach(audio.outputs) { output in Text(output.name).tag(output.id) }
                }.labelsHidden().frame(width: 220).controlSize(.large)
                    .disabled(audio.isStarting)
                    .help("Follows the Mac’s default output. Choosing a device changes the system output.")
            }
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 6) {
                sectionLabel("PREAMP")
                HStack(spacing: 9) {
                    NativeGainSlider(value: $model.preset.preampDB, enabled: true, label: "Preamp gain",
                                     range: -60...12, vertical: false).frame(width: 108, height: 24)
                    TextField("Preamp", value: $model.preset.preampDB, format: .number.precision(.fractionLength(1)))
                        .textFieldStyle(.roundedBorder).frame(width: 54).accessibilityLabel("Preamp in decibels")
                    Text("dB").foregroundStyle(.secondary).font(.caption)
                }
            }
            Toggle("Bypass", isOn: $model.bypassed).toggleStyle(.switch).controlSize(.small)
                .help("Compare with unfiltered audio, including removal of preamp gain. ⌘B")
        }
    }

    private var bandSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionLabel("FREQUENCY BANDS")
                Text("\(model.preset.bands.count) / 32").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                Spacer()
                Button(action: model.addBand) { Label("Add band", systemImage: "plus") }
                    .disabled(model.preset.bands.count >= 32)
                Button { model.choose(.flat) } label: { Label("Reset", systemImage: "arrow.counterclockwise") }
                    .help("Return to ten flat bands. Saved presets are kept.")
            }
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach($model.preset.bands) { $band in
                        BandStrip(band: $band, selected: model.selectedBandID == band.id,
                                  sampleRate: audio.isRunning && !model.bypassed ? audio.sampleRate : nil) {
                            model.selectedBandID = band.id
                        }
                    }
                }.padding(.bottom, 6)
            }
            .scrollIndicators(.visible)
        }
    }

    @ViewBuilder private var inspector: some View {
        if let index = model.preset.bands.firstIndex(where: { $0.id == model.selectedBandID }) {
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    sectionLabel("FILTER")
                    Picker("Filter type", selection: $model.preset.bands[index].type) {
                        ForEach(EQFilterType.allCases, id: \.self) { Text($0.label).tag($0) }
                    }.labelsHidden().frame(width: 138)
                }
                numericField("FREQUENCY", value: $model.preset.bands[index].frequency, unit: "Hz", width: 80)
                numericField("GAIN", value: $model.preset.bands[index].gainDB, unit: "dB", width: 65)
                    .disabled(!model.preset.bands[index].type.hasGain)
                numericField("Q", value: $model.preset.bands[index].q, unit: "", width: 65)
                Spacer()
                Toggle("Enabled", isOn: $model.preset.bands[index].enabled).toggleStyle(.switch).controlSize(.small)
                Button(role: .destructive, action: model.removeSelectedBand) { Image(systemName: "trash") }
                    .help("Remove selected band").accessibilityLabel("Remove selected band")
            }.padding(16).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private var footer: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                Label(audio.status, systemImage: audio.isRunning ? "speaker.wave.2" : "info.circle")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Text("Audio stays on your Mac. Closing this window keeps EQ running.")
                    .font(.caption2).foregroundStyle(.tertiary)
                if let attribution = model.preset.attribution {
                    Button("Profile credits") { showingCredits = true }
                        .buttonStyle(.link).font(.caption2)
                        .popover(isPresented: $showingCredits) {
                            Text(attribution).font(.caption).textSelection(.enabled).padding(20).frame(width: 440)
                        }
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 5) {
                HStack(spacing: 10) {
                    Text(audio.isRunning ? String(format: "%.1f kHz", audio.sampleRate / 1000) : "— kHz")
                    Text(audio.isRunning && audio.peakDB.isFinite ? String(format: "Peak %.1f dBFS", audio.peakDB) : "Peak —")
                    if audio.clipping { Label("Clipping", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Button("Apply recommended headroom") {
                    let gain = model.preset.recommendedPreamp(sampleRate: audio.sampleRate > 0 ? audio.sampleRate : 48000)
                    if gain.isFinite { model.preset.preampDB = gain }
                    else { model.message = "This preset cannot run at the selected output’s sample rate. Check the active band frequencies." }
                }.buttonStyle(.link).font(.caption)
                    .help("Attenuates the estimated EQ boost. This is headroom guidance, not a limiter.")
            }
        }
    }

    private var saveSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Save a preset").font(.title2.bold())
            Text("Keep this tuning as a new preset.").foregroundStyle(.secondary)
            TextField("Preset name", text: $model.saveName).textFieldStyle(.roundedBorder).frame(width: 320)
            HStack {
                Spacer()
                Button("Cancel") { showingSave = false }.keyboardShortcut(.cancelAction)
                Button("Save a Copy") { model.savePreset(); showingSave = false }.keyboardShortcut(.defaultAction)
                    .disabled(model.saveName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(26)
    }

    private var presetSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Saved presets").font(.title2.bold())
            List(model.presets) { preset in
                HStack {
                    Button(preset.name) { model.choose(preset); showingPresets = false }.buttonStyle(.plain)
                    Spacer()
                    Button(role: .destructive) { model.deletePreset(preset.id) } label: { Image(systemName: "trash") }
                        .accessibilityLabel("Delete \(preset.name)")
                }
            }.frame(width: 380, height: 250)
            HStack { Spacer(); Button("Done") { showingPresets = false }.keyboardShortcut(.defaultAction) }
        }.padding(24)
    }

    private func numericField(_ label: String, value: Binding<Double>, unit: String, width: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel(label)
            HStack(spacing: 5) {
                TextField(label, value: value, format: .number.precision(.fractionLength(0...2)))
                    .textFieldStyle(.roundedBorder).frame(width: width).accessibilityLabel("\(label) \(unit)")
                Text(unit).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func sectionLabel(_ label: String) -> some View {
        Text(label).font(.system(size: 10, weight: .semibold)).tracking(1.3).foregroundStyle(.secondary)
    }
}

private struct BandStrip: View {
    @Binding var band: EQBand
    let selected: Bool
    let sampleRate: Double?
    let select: () -> Void
    @State private var dragStart: Double?
    @GestureState private var isDragging = false

    private var maximumFrequency: Double {
        guard band.enabled, let sampleRate else { return 20_000 }
        return min(20_000, (sampleRate / 2 * 100).rounded(.down) / 100 - 0.01)
    }

    var body: some View {
        VStack(spacing: 7) {
            Button(action: select) {
                VStack(spacing: 4) {
                    Text(band.frequency >= 1000 ? String(format: "%.1fk", band.frequency / 1000) : String(format: "%.0f", band.frequency))
                        .font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text("Hz").font(.system(size: 9)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("Edit \(band.frequency, specifier: "%.0f") hertz band")
                .help("Drag right or up to raise frequency; left or down to lower it. Click to edit exact values below.")
                .simultaneousGesture(DragGesture(minimumDistance: 3, coordinateSpace: .global)
                    .updating($isDragging) { _, state, _ in state = true }
                    .onChanged { gesture in
                        if dragStart == nil { dragStart = band.frequency; select() }
                        band.frequency = scrubbedFrequency(from: dragStart ?? band.frequency,
                                                           translation: gesture.translation, maximum: maximumFrequency)
                    })
                .onChange(of: isDragging) { _, dragging in if !dragging { dragStart = nil } }
                .accessibilityAdjustableAction { direction in
                    select()
                    switch direction {
                    case .increment: band.frequency = scrubbedFrequency(from: band.frequency, translation: CGSize(width: 10, height: 0), maximum: maximumFrequency)
                    case .decrement: band.frequency = scrubbedFrequency(from: band.frequency, translation: CGSize(width: -10, height: 0), maximum: maximumFrequency)
                    @unknown default: break
                    }
                }
            NativeGainSlider(value: $band.gainDB, enabled: band.enabled && band.type.hasGain,
                             label: "\(Int(band.frequency)) hertz gain", range: -24...24, vertical: true)
                .frame(width: 32, height: 112)
            Text(band.type.hasGain ? String(format: "%+.1f", band.gainDB) : band.type.shortLabel)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(band.enabled ? .primary : .tertiary)
            Toggle("Band enabled", isOn: $band.enabled).labelsHidden().toggleStyle(.checkbox)
                .accessibilityLabel("Enable \(band.frequency, specifier: "%.0f") hertz band")
        }
        .padding(.vertical, 12).frame(width: 82)
        .background(selected ? Color.teal.opacity(0.09) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(selected ? Color.teal.opacity(0.55) : Color.primary.opacity(0.06), lineWidth: 1))
        .onTapGesture(perform: select)
    }
}

private struct NativeGainSlider: NSViewRepresentable {
    @Binding var value: Double
    let enabled: Bool
    let label: String
    let range: ClosedRange<Double>
    let vertical: Bool

    func makeCoordinator() -> Coordinator { Coordinator(value: $value) }
    func makeNSView(context: Context) -> NSSlider {
        let slider = ResettableGainSlider(value: value, minValue: range.lowerBound, maxValue: range.upperBound,
                              target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        slider.isVertical = vertical
        slider.isContinuous = true
        slider.toolTip = "Double-click to reset to 0 dB."
        return slider
    }
    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.value = $value
        slider.doubleValue = value
        slider.isEnabled = enabled
        slider.setAccessibilityLabel(label)
        slider.setAccessibilityValueDescription(String(format: "%.1f decibels", value))
        slider.setAccessibilityHelp("Double-click to reset to zero decibels. Arrow keys adjust gain.")
    }
    final class Coordinator: NSObject {
        var value: Binding<Double>
        init(value: Binding<Double>) { self.value = value }
        @objc func changed(_ slider: NSSlider) { value.wrappedValue = (slider.doubleValue * 10).rounded() / 10 }
    }
}

private final class ResettableGainSlider: NSSlider {
    override func mouseDown(with event: NSEvent) {
        if isEnabled, event.clickCount >= 2 {
            doubleValue = 0
            sendAction(action, to: target)
        } else {
            super.mouseDown(with: event)
        }
    }
}

private func scrubbedFrequency(from start: Double, translation: CGSize, maximum: Double) -> Double {
    // One octave per 120 points keeps low and high frequencies equally easy to tune.
    let frequency = start * pow(2, (translation.width - translation.height) / 120)
    return max(10, min(maximum, (frequency * 100).rounded() / 100))
}

#if DEBUG
extension EqualizerView {
    static func checkControlGestures() {
        func value(_ x: Double, _ y: Double, start: Double = 1000, maximum: Double = 20_000) -> Double {
            scrubbedFrequency(from: start, translation: CGSize(width: x, height: y), maximum: maximum)
        }
        precondition(value(0, 0, start: 31.25) == 31.25)
        precondition(value(120, 0) == 2000 && value(0, -120) == 2000)
        precondition(value(-120, 0) == 500 && value(0, 120) == 500)
        precondition(value(12000, 0) == 20_000 && value(-12000, 0) == 10)
        precondition(value(120, 0, start: 16_000, maximum: 15_999.99) == 15_999.99)
    }
}
#endif

private struct ResponseGraph: View, Equatable {
    let preset: EQPreset
    let sampleRate: Double
    let bypassed: Bool
    var body: some View {
        Canvas { context, size in
            let rect = CGRect(x: 40, y: 27, width: max(1, size.width - 62), height: max(1, size.height - 54))
            let maxFrequency = min(20000.0, sampleRate * 0.49)
            func x(_ f: Double) -> Double { rect.minX + log(f / 20) / log(maxFrequency / 20) * rect.width }
            func y(_ db: Double) -> Double { rect.midY - max(-24, min(24, db)) / 48 * rect.height }
            for db in [-24.0, -12, 0, 12, 24] {
                var line = Path(); line.move(to: CGPoint(x: rect.minX, y: y(db))); line.addLine(to: CGPoint(x: rect.maxX, y: y(db)))
                context.stroke(line, with: .color(.primary.opacity(db == 0 ? 0.18 : 0.07)), style: StrokeStyle(lineWidth: 1, dash: db == 0 ? [] : [3, 5]))
                context.draw(Text("\(Int(db))").font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary), at: CGPoint(x: 21, y: y(db)))
            }
            for f in [20.0, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000] where f <= maxFrequency {
                var line = Path(); line.move(to: CGPoint(x: x(f), y: rect.minY)); line.addLine(to: CGPoint(x: x(f), y: rect.maxY))
                context.stroke(line, with: .color(.primary.opacity(0.055)))
                let label = f >= 1000 ? "\(Int(f / 1000))k" : "\(Int(f))"
                context.draw(Text(label).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary), at: CGPoint(x: x(f), y: rect.maxY + 16))
            }
            var curve = Path()
            for i in 0...384 {
                let f = 20 * pow(maxFrequency / 20, Double(i) / 384)
                let db = bypassed ? 0 : preset.responseDB(at: f, sampleRate: sampleRate)
                let point = CGPoint(x: x(f), y: y(db.isFinite ? db : -24))
                if i == 0 { curve.move(to: point) } else { curve.addLine(to: point) }
            }
            var fill = curve
            fill.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            fill.addLine(to: CGPoint(x: rect.minX, y: rect.maxY)); fill.closeSubpath()
            context.fill(fill, with: .linearGradient(Gradient(colors: [.teal.opacity(0.18), .teal.opacity(0.01)]), startPoint: CGPoint(x: 0, y: rect.minY), endPoint: CGPoint(x: 0, y: rect.maxY)))
            context.stroke(curve, with: .color(bypassed ? .secondary : .teal), style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
        .overlay(alignment: .topLeading) {
            Text(bypassed ? "BYPASSED · UNITY RESPONSE" : "EQ RESPONSE · dB")
                .font(.system(size: 9, weight: .medium)).tracking(1).foregroundStyle(.secondary).padding(.leading, 14).padding(.top, 10)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Equalizer frequency response")
        .accessibilityValue(bypassed ? "Bypassed. Flat response." : "\(preset.bands.filter(\.enabled).count) enabled filters. Preamp \(String(format: "%.1f", preset.preampDB)) decibels. Edit exact values with the band controls below.")
    }
}

private struct ControlSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), !reduceTransparency {
            content.glassEffect(.regular, in: .capsule)
        } else {
            content.background(Color(nsColor: .controlBackgroundColor), in: Capsule())
        }
    }
}

private extension EQFilterType {
    var label: String {
        switch self {
        case .peak: return "Peaking"
        case .lowShelf: return "Low shelf"
        case .highShelf: return "High shelf"
        case .lowPass: return "Low pass"
        case .highPass: return "High pass"
        case .notch: return "Notch"
        }
    }
    var shortLabel: String {
        switch self {
        case .lowPass: return "LP"
        case .highPass: return "HP"
        case .notch: return "NO"
        default: return "EQ"
        }
    }
    var hasGain: Bool { self == .peak || self == .lowShelf || self == .highShelf }
}
