import AppKit
import Combine
import EQCore
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    let audio = AudioController()
    @Published var preset = EQPreset.flat { didSet { changed() } }
    @Published var presets: [EQPreset] = []
    @Published var bypassed = false { didSet { changed() } }
    @Published var message: String?
    @Published var selectedBandID: UUID?
    @Published var saveName = "My preset"
    private var store: PresetStore?
    private var persistenceTask: Task<Void, Never>?

    init() {
        do {
            let storage = try PresetStore()
            let library = try storage.load()
            store = storage
            presets = library.presets
            preset = library.lastPreset ?? library.presets.first ?? .flat
        } catch {
            message = "Could not load presets: \(error.localizedDescription). Your existing file has been preserved."
        }
        selectedBandID = preset.bands.first?.id
        audio.refreshDevices()
    }

    func changed() {
        do {
            try preset.validate()
            audio.update(preset: preset, bypassed: bypassed)
            persistenceTask?.cancel()
            persistenceTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled else { return }
                self?.persist()
            }
        } catch { message = error.localizedDescription }
    }

    func toggleProcessing() {
        guard !audio.isStarting else { return }
        if audio.isRunning { audio.stop() }
        else { audio.start(preset: preset, bypassed: bypassed) }
    }

    func choose(_ value: EQPreset) {
        preset = value
        selectedBandID = value.bands.first?.id
        saveName = value.name
    }

    func savePreset() {
        let name = saveName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { message = "Give your preset a name."; return }
        do {
            try preset.validate()
            var saved = preset
            saved.name = name
            try saved.validate()
            // Saving is always a new copy; a tuning session cannot overwrite another preset.
            saved.id = UUID()
            presets.append(saved)
            preset = saved
            persist()
        } catch { message = error.localizedDescription }
    }

    func deletePreset(_ id: UUID) {
        presets.removeAll { $0.id == id }
        persist()
    }

    func addBand() {
        guard preset.bands.count < 32 else { return }
        let band = EQBand(type: .peak, enabled: true, frequency: 1000, gainDB: 0, q: 1)
        preset.bands.append(band)
        selectedBandID = band.id
    }

    func removeSelectedBand() {
        guard let id = selectedBandID else { return }
        preset.bands.removeAll { $0.id == id }
        selectedBandID = preset.bands.first?.id
    }

    func importPreset() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText]
        panel.allowsMultipleSelection = false
        panel.message = "Import a supported Equalizer APO parametric preset."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let attributes = try url.resourceValues(forKeys: [.fileSizeKey])
            guard (attributes.fileSize ?? 0) <= APOCodec.maximumBytes else {
                throw CocoaError(.fileReadTooLarge)
            }
            let imported = try APOCodec.parse(String(contentsOf: url, encoding: .utf8), name: url.deletingPathExtension().lastPathComponent)
            choose(imported)
        } catch { message = "Import failed: \(error.localizedDescription)" }
    }

    func exportPreset() {
        do { try preset.validate() }
        catch { message = error.localizedDescription; return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = preset.name + ".txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try APOCodec.export(preset).write(to: url, atomically: true, encoding: .utf8) }
        catch { message = "Export failed: \(error.localizedDescription)" }
    }

    func persist() {
        guard let store else { return }
        do {
            let selected = presets.contains(where: { $0.id == preset.id }) ? preset.id : nil
            try store.save(PresetLibrary(presets: presets, selectedPresetID: selected, lastPreset: preset))
        } catch { message = "Could not save presets: \(error.localizedDescription)" }
    }

    func shutDown() {
        persistenceTask?.cancel()
        persist()
        audio.shutdown()
    }
}
