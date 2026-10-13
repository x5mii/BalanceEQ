import Foundation

public struct PresetLibrary: Codable, Equatable, Sendable {
    public var version: Int = 1
    public var presets: [EQPreset]
    public var selectedPresetID: UUID?
    public var lastPreset: EQPreset?

    public init(presets: [EQPreset] = [], selectedPresetID: UUID? = nil, lastPreset: EQPreset? = nil) {
        self.presets = presets
        self.selectedPresetID = selectedPresetID
        self.lastPreset = lastPreset
    }

    public func validate() throws {
        guard version == 1 else { throw EQError.invalid("Unsupported library version \(version).") }
        guard presets.count <= 1_000 else { throw EQError.invalid("The library supports at most 1,000 presets.") }
        guard Set(presets.map(\.id)).count == presets.count else { throw EQError.invalid("Duplicate preset identifiers in the library.") }
        if let selectedPresetID, !presets.contains(where: { $0.id == selectedPresetID }) {
            throw EQError.invalid("The selected preset is missing from the library.")
        }
        for preset in presets { try preset.validate() }
        try lastPreset?.validate()
    }
}

/// One local JSON document; callers decide when to save named presets or the current draft.
public final class PresetStore {
    public let fileURL: URL
    public let backupURL: URL
    private let maximumBytes = 8 * 1_024 * 1_024

    public init(directory: URL? = nil) throws {
        let directory = try directory ?? FileManager.default.url(for: .applicationSupportDirectory,
                                                                 in: .userDomainMask, appropriateFor: nil, create: false)
            .appendingPathComponent("EqualizerForMac", isDirectory: true)
        fileURL = directory.appendingPathComponent("state.json")
        backupURL = directory.appendingPathComponent("state.backup.json")
    }

    public func load() throws -> PresetLibrary {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            let flat = EQPreset.flat
            return PresetLibrary(presets: [flat], selectedPresetID: flat.id, lastPreset: flat)
        }
        return try decode(read(fileURL))
    }

    public func save(_ library: PresetLibrary) throws {
        try library.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(library)
        guard data.count <= maximumBytes else { throw EQError.invalid("The preset library is too large to save.") }
        var previous: Data?
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let data = try read(fileURL)
            _ = try decode(data)
            previous = data
        }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let previous { try previous.write(to: backupURL, options: .atomic) }
        try data.write(to: fileURL, options: .atomic)
    }

    private func read(_ url: URL) throws -> Data {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= maximumBytes else { throw EQError.invalid("The saved library is too large. The original file has been preserved.") }
        let data = try Data(contentsOf: url)
        guard data.count <= maximumBytes else { throw EQError.invalid("The saved library is too large. The original file has been preserved.") }
        return data
    }

    private func decode(_ data: Data) throws -> PresetLibrary {
        do {
            let library = try JSONDecoder().decode(PresetLibrary.self, from: data)
            try library.validate()
            return library
        } catch {
            throw EQError.invalid("Could not load saved presets: \(error.localizedDescription) The original file has been preserved at \(fileURL.path).")
        }
    }
}
