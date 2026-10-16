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
    @State private var liveSpectrum = false
    @State private var showingGraphHelp = false

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    controls
                    HStack {
                        Picker("Graph", selection: $liveSpectrum) {
                            Text("EQ response").tag(false)
                            Text("Live audio").tag(true)
                        }.pickerStyle(.segmented).labelsHidden().frame(width: 220)
                        Spacer()
                        Text(liveSpectrum ? "Before / after EQ · dBFS" : "Calculated filter response · dB")
                            .font(.caption).foregroundStyle(.secondary)
                        Button { showingGraphHelp = true } label: { Image(systemName: "info.circle") }
                            .buttonStyle(.plain).accessibilityLabel("About the graphs and Harman targets")
                            .popover(isPresented: $showingGraphHelp) {
                                Text("EQ response shows calculated filter gain. Live audio shows actual digital samples before and after EQ. Harman-target profiles apply a headphone correction; verifying acoustic target matching requires compatible headphone measurements. The live spectrum cannot measure your headphones.")
                                    .font(.callout).padding(20).frame(width: 360)
                            }
                    }
                    if liveSpectrum {
                        SpectrumGraph(model: audio.spectrum, running: audio.isRunning)
                            .frame(height: 182)
                    } else {
                    ResponseGraph(preset: model.preset, sampleRate: audio.sampleRate > 0 ? audio.sampleRate : 48000, bypassed: model.bypassed)
                        .equatable()
                        .frame(height: 182)
                    }
                    bandSection
                    inspector
                    footer
                }.padding(.horizontal, 20).padding(.vertical, 12)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 930, minHeight: 740)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(.blue)
        .onAppear {
            appDelegate.reopen = { openWindow(id: "equalizer") }
            audio.setAnalysisEnabled(liveSpectrum)
        }
        .onDisappear { audio.setAnalysisEnabled(false) }
        .onChange(of: liveSpectrum) { _, enabled in audio.setAnalysisEnabled(enabled) }
        .alert("BalanceEQ", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("OK") { model.message = nil }
        } message: { Text(model.message ?? "") }
        .sheet(isPresented: $showingSave) { saveSheet }
        .sheet(isPresented: $showingPresets) { presetSheet }
        .sheet(isPresented: $showingHeadphones) { HeadphoneProfilesView(model: model) }
    }

    private var header: some View {
        HStack(spacing: 14) {
            BalanceLogo().frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text("BalanceEQ").font(.system(size: 23, weight: .semibold, design: .rounded))
                Text("Your Mac. Your sound.").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 7) {
                Circle().fill(audio.isRunning ? Color.blue : Color.secondary).frame(width: 7, height: 7)
                Text(audio.isStarting ? "STARTING" : (audio.isRunning ? (model.bypassed ? "BYPASSED" : "PROCESSING") : "READY"))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(1.2)
            }.padding(.horizontal, 12).padding(.vertical, 9).background(Color(nsColor: .controlBackgroundColor), in: Capsule())
            Button(action: model.toggleProcessing) {
                Label(audio.isStarting ? "Starting…" : (audio.isRunning ? "Stop" : "Start EQ"), systemImage: audio.isRunning ? "stop.fill" : "play.fill")
                    .frame(minWidth: 78)
            }.modifier(PrimaryActionStyle()).controlSize(.large)
                .disabled(audio.isStarting)
                .help("Start or stop processing the normal system output")
        }.padding(.horizontal, 22).padding(.top, 28).padding(.bottom, 8)
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
                    DecimalField(label: "Preamp in decibels", value: $model.preset.preampDB, range: -60...12)
                        .textFieldStyle(.roundedBorder).frame(width: 54).accessibilityLabel("Preamp in decibels")
                    Text("dB").foregroundStyle(.secondary).font(.caption).fixedSize()
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
                }.padding(8)
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
            .scrollBounceBehavior(.basedOnSize)
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
                numericField("FREQUENCY", value: $model.preset.bands[index].frequency, unit: "Hz", width: 80, range: 10...(audio.isRunning && !model.bypassed && model.preset.bands[index].enabled ? min(20_000, audio.sampleRate / 2 - 0.01) : 20_000))
                numericField("GAIN", value: $model.preset.bands[index].gainDB, unit: "dB", width: 65, range: -24...24)
                    .disabled(!model.preset.bands[index].type.hasGain)
                numericField("Q", value: $model.preset.bands[index].q, unit: "", width: 65, range: 0.1...30)
                Spacer()
                Toggle("Enabled", isOn: $model.preset.bands[index].enabled).toggleStyle(.switch).controlSize(.small)
                Button(role: .destructive, action: model.removeSelectedBand) { Image(systemName: "trash") }
                    .help("Remove selected band").accessibilityLabel("Remove selected band")
            }.padding(16).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
                .id(model.selectedBandID)
        }
    }

    private var footer: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                Label(audio.status, systemImage: audio.isRunning ? "speaker.wave.2" : "info.circle")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                HStack(spacing: 10) {
                    Text("Close this window to keep EQ running in the menu bar.")
                        .foregroundStyle(.tertiary)
                    if let attribution = model.preset.attribution {
                        Button("Profile credits") { showingCredits = true }
                            .buttonStyle(.link)
                            .popover(isPresented: $showingCredits) {
                                Text(attribution).font(.caption).textSelection(.enabled).padding(20).frame(width: 440)
                            }
                    }
                }.font(.caption2)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 5) {
                OutputLevels(levels: audio.levels, running: audio.isRunning, sampleRate: audio.sampleRate)
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

    private func numericField(_ label: String, value: Binding<Double>, unit: String, width: Double, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel(label)
            HStack(spacing: 5) {
                DecimalField(label: "\(label) \(unit)", value: value, range: range)
                    .textFieldStyle(.roundedBorder).frame(width: width).accessibilityLabel("\(label) \(unit)")
                Text(unit).font(.caption).foregroundStyle(.secondary).fixedSize()
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
                .frame(width: 32, height: 84)
            Text(band.type.hasGain ? String(format: "%+.1f", band.gainDB) : band.type.shortLabel)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(band.enabled ? .primary : .tertiary)
            Toggle("Band enabled", isOn: $band.enabled).labelsHidden().toggleStyle(.checkbox)
                .accessibilityLabel("Enable \(band.frequency, specifier: "%.0f") hertz band")
        }
        .padding(.vertical, 10).frame(width: 80)
        .background(selected ? Color.blue.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .top) {
            Capsule().fill(selected ? Color.blue : .clear).frame(width: 20, height: 3)
        }
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
        if vertical { slider.cell = EQGainCell() }
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.changed(_:))
        slider.isVertical = vertical
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.doubleValue = value
        slider.isContinuous = true
        slider.toolTip = "Double-click to reset to 0 dB."
        return slider
    }
    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.value = $value
        if slider.doubleValue != value { slider.doubleValue = value }
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

/// Keep AppKit's tracking, keyboard and accessibility; only replace the vertical artwork.
private final class EQGainCell: NSSliderCell {
    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let rail = NSRect(x: rect.midX - 1.5, y: rect.minY, width: 3, height: rect.height)
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: rail, xRadius: 1.5, yRadius: 1.5).fill()
        let thumb = knobRect(flipped: flipped)
        let center = rect.midY
        let amount = NSRect(x: rail.minX, y: min(center, thumb.midY), width: 3, height: abs(center - thumb.midY))
        (isEnabled ? NSColor.systemBlue : NSColor.tertiaryLabelColor).setFill()
        NSBezierPath(roundedRect: amount, xRadius: 1.5, yRadius: 1.5).fill()
        let zero = NSBezierPath()
        zero.move(to: NSPoint(x: rect.midX - 7, y: center))
        zero.line(to: NSPoint(x: rect.midX + 7, y: center))
        NSColor.tertiaryLabelColor.withAlphaComponent(0.5).setStroke()
        zero.lineWidth = 1
        zero.stroke()
    }
    override func drawKnob(_ knobRect: NSRect) {
        let circle = NSBezierPath(ovalIn: NSRect(x: knobRect.midX - 6, y: knobRect.midY - 6, width: 12, height: 12))
        NSColor.controlBackgroundColor.setFill()
        circle.fill()
        (isEnabled ? NSColor.systemBlue : NSColor.tertiaryLabelColor).setStroke()
        circle.lineWidth = 2
        circle.stroke()
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
        let maximum = min(20_000, sampleRate * 0.49)
        let frequencies = (0...384).map { 20 * pow(maximum / 20, Double($0) / 384) }
        let values = bypassed ? frequencies.map { _ in 0.0 } : preset.responseDB(at: frequencies, sampleRate: sampleRate)
        EQPlot(after: values, range: -24...24, muted: bypassed)
            .padding(.leading, 40).padding(.trailing, 20).padding(.top, 32).padding(.bottom, 26)
            .background(PlotGrid(range: -24...24, maximum: maximum).equatable())
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

private struct PrimaryActionStyle: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), !reduceTransparency {
            content.buttonStyle(.glassProminent)
        } else {
            content.buttonStyle(.borderedProminent)
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

private struct OutputLevels: View {
    @ObservedObject var levels: AudioLevels
    let running: Bool
    let sampleRate: Double
    var body: some View {
        HStack(spacing: 10) {
            Text(running ? String(format: "%.1f kHz", sampleRate / 1000) : "— kHz")
            Text(running ? String(format: "Peak %.1f dBFS", levels.peakDB) : "Peak —")
            if levels.clipping { Label("Clipping", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
        }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
    }
}
