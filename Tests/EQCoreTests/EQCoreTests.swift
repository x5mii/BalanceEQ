import XCTest
@testable import EQCore

final class EQCoreTests: XCTestCase {
    func testFlatValidationAndSampleRateChanges() throws {
        var flat = EQPreset.flat
        XCTAssertEqual(flat.bands.count, 10)
        try flat.validate(sampleRate: 44_100)
        XCTAssertEqual(flat.responseDB(at: 1_000, sampleRate: 48_000), 0, accuracy: 0.000_001)
        XCTAssertEqual(flat.recommendedPreamp(sampleRate: 48_000), 0, accuracy: 0.000_001)
        XCTAssertThrowsError(try flat.parameters(sampleRate: 32_000))
        flat.bands[9].enabled = false
        XCTAssertNoThrow(try flat.parameters(sampleRate: 32_000))
        XCTAssertThrowsError(try flat.parameters(sampleRate: .nan))
        XCTAssertThrowsError(try flat.parameters(sampleRate: 0))
    }

    func testRejectsInvalidPresetData() {
        var preset = EQPreset.flat
        for invalid in [Double.nan, .infinity, -.infinity, -61, 13] {
            preset.preampDB = invalid
            XCTAssertThrowsError(try preset.validate())
        }
        preset = .flat
        for invalid in [Double.nan, .infinity, -1, 9, 20_001] {
            preset.bands[0].frequency = invalid
            XCTAssertThrowsError(try preset.validate())
        }
        preset = .flat
        for invalid in [Double.nan, -25, 25] {
            preset.bands[0].gainDB = invalid
            XCTAssertThrowsError(try preset.validate())
        }
        preset = .flat
        for invalid in [Double.nan, 0, 0.09, 30.01] {
            preset.bands[0].q = invalid
            XCTAssertThrowsError(try preset.validate())
        }
        preset = .flat
        preset.bands[1].id = preset.bands[0].id
        XCTAssertThrowsError(try preset.validate())
        preset = .flat
        preset.bands = (0...32).map { _ in EQBand() }
        XCTAssertThrowsError(try preset.validate())
        preset = .flat
        preset.version = 2
        XCTAssertThrowsError(try preset.validate())
        preset = .flat
        preset.name = " \n "
        XCTAssertThrowsError(try preset.validate())
    }

    func testEngineResponseAndHeadroomUseEnabledBands() throws {
        var preset = EQPreset(name: "Peak", preampDB: -2, bands: [EQBand(frequency: 1_000, gainDB: 6, q: 2)])
        try preset.validate(sampleRate: 48_000)
        XCTAssertEqual(preset.responseDB(at: 1_000, sampleRate: 48_000), 4, accuracy: 0.000_01)
        XCTAssertEqual(preset.recommendedPreamp(sampleRate: 48_000), -6, accuracy: 0.01)
        let parameters = try preset.parameters(sampleRate: 48_000)
        XCTAssertEqual(parameters.count, 1)
        XCTAssertEqual(parameters.preampDB, -2)
        XCTAssertEqual(parameters.bypass, 0)
        XCTAssertEqual(try preset.parameters(sampleRate: 48_000, bypassed: true).bypass, 1)
        preset.bands[0].enabled = false
        XCTAssertEqual(preset.responseDB(at: 1_000, sampleRate: 48_000), -2, accuracy: 0.000_01)
        XCTAssertEqual(preset.recommendedPreamp(sampleRate: 48_000), 0)
        XCTAssertTrue(preset.responseDB(at: 24_000, sampleRate: 48_000).isNaN)
    }

    func testSupportedAPOFormsRoundTrip() throws {
        let text = """
        # Exported EQ
        Preamp: -6 dB
        Filter 1: ON PK Fc 31.25 Hz Gain 3.5 dB Q 1.4
        Filter 2: OFF PEQ Fc 200 Hz Gain -2 dB Q 2 # disabled band
        Filter 3: ON LSC Fc 100 Hz Gain 3 dB Q 0.7
        Filter 4: ON HSC Fc 10000 Hz Gain -3 dB Q 0.7
        Filter 5: ON HPQ Fc 20 Hz Q 0.8
        Filter 6: ON LPQ Fc 16000 Hz Q 0.9
        Filter 7: ON NO Fc 1000 Hz Q 5
        Filter 8: OFF NO Fc 4000 Hz
        """
        let first = try APOCodec.parse(text, name: "Imported")
        let second = try APOCodec.parse(APOCodec.export(first), name: first.name)
        XCTAssertEqual(first.preampDB, second.preampDB)
        XCTAssertEqual(first.bands.count, 8)
        XCTAssertEqual(first.bands[7].q, 30)
        XCTAssertEqual(first.bands.count, second.bands.count)
        for (left, right) in zip(first.bands, second.bands) {
            XCTAssertEqual(left.type, right.type)
            XCTAssertEqual(left.enabled, right.enabled)
            XCTAssertEqual(left.frequency, right.frequency)
            XCTAssertEqual(left.gainDB, right.gainDB)
            XCTAssertEqual(left.q, right.q)
        }
        for frequency in [20.0, 80, 500, 5_000, 15_000] {
            XCTAssertEqual(first.responseDB(at: frequency, sampleRate: 48_000),
                           second.responseDB(at: frequency, sampleRate: 48_000), accuracy: 0.000_001)
        }
        XCTAssertEqual(try APOCodec.parse("\u{FEFF}preamp: -2 DB\r\n# comment\r\n", name: "BOM").preampDB, -2)
        XCTAssertEqual(try APOCodec.parse("Filter 1: ON NO Fc 1.000 Hz", name: "Grouped frequency").bands[0].frequency, 1_000)
        let fractional = EQPreset(name: "Fractional", bands: [EQBand(frequency: 31.125)])
        XCTAssertTrue(APOCodec.export(fractional).contains("31.125e0"))
        XCTAssertEqual(try APOCodec.parse(APOCodec.export(fractional), name: "Fractional").bands[0].frequency, 31.125)
    }

    func testAPORejectsUnsupportedOrMalformedInputAtomically() throws {
        let invalidLines = [
            "Include: other.txt", "Device: Speakers", "Channel: L", "GraphicEQ: 20 0; 100 2",
            "Filter 1: ON LS Fc 100 Hz Gain 2 dB", "Filter 1: ON LSC 6 dB Fc 100 Hz Gain 2 dB",
            "Filter 1: ON PEQ Fc 100 Hz Gain 2 dB BW Oct 1", "Filter 1: ON PK Fc 100 Hz Gain 2 dB Q 1 trailing",
            "Filter 1: ON PK Fc nan Hz Gain 2 dB Q 1", "Filter 1: ON PK Fc 100 Hz Gain inf dB Q 1",
            "Filter 1: ON PK Fc 100 Hz Gain 2 dB Q 0", "Filter 1: ON PK Fc 100 Hz Gain 25 dB Q 1",
            "Filter 1: ON HPQ Fc 100 Hz", "Filter 1: ON AP Fc 100 Hz Q 1", "Filter 0: ON NO Fc 100 Hz Q 1",
            "Filter x: ON NO Fc 100 Hz Q 1", "Preamp: NaN dB", "Preamp: -61 dB", "not a command"
        ]
        for invalidLine in invalidLines {
            XCTAssertThrowsError(try APOCodec.parse("# comment\r\n\(invalidLine)", name: "Bad")) { error in
                guard case EQError.line(2, _) = error else { return XCTFail("Missing source line: \(error)") }
            }
        }
        XCTAssertThrowsError(try APOCodec.parse("Preamp: 0 dB\nPreamp: 1 dB", name: "Duplicate"))
        XCTAssertThrowsError(try APOCodec.parse("Filter 1: ON NO Fc 100 Hz\nFilter 01: OFF NO Fc 200 Hz", name: "Duplicate"))
        XCTAssertThrowsError(try APOCodec.parse("# only comments\n", name: "Empty"))
        XCTAssertThrowsError(try APOCodec.parse(String(repeating: "#", count: APOCodec.maximumBytes + 1), name: "Large"))
        let tooMany = (1...33).map { "Filter \($0): ON NO Fc 100 Hz" }.joined(separator: "\n")
        XCTAssertThrowsError(try APOCodec.parse(tooMany, name: "Too many"))
    }

    func testPersistencePreservesLastValidFileAndRejectsCorruption() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PresetStore(directory: directory)
        var library = try store.load()
        XCTAssertEqual(library.presets.count, 1)
        XCTAssertEqual(library.selectedPresetID, library.presets[0].id)
        try store.save(library)
        XCTAssertEqual(try store.load(), library)
        let previous = try Data(contentsOf: store.fileURL)
        library.lastPreset?.preampDB = -3
        try store.save(library)
        XCTAssertEqual(try Data(contentsOf: store.backupURL), previous)
        XCTAssertEqual(try store.load(), library)
        let invalid = Data("broken JSON".utf8)
        try invalid.write(to: store.fileURL)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save(library))
        XCTAssertEqual(try Data(contentsOf: store.fileURL), invalid)
        XCTAssertEqual(try Data(contentsOf: store.backupURL), previous)
    }

    func testLibraryRejectsVersionAndDuplicateIdentifiersWithoutOverwriting() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PresetStore(directory: directory)
        var library = try store.load()
        try store.save(library)
        let original = try Data(contentsOf: store.fileURL)
        library.presets.append(library.presets[0])
        XCTAssertThrowsError(try store.save(library))
        XCTAssertEqual(try Data(contentsOf: store.fileURL), original)
        library = try store.load()
        library.version = 2
        XCTAssertThrowsError(try store.save(library))
        library.version = 1
        library.selectedPresetID = UUID()
        XCTAssertThrowsError(try store.save(library))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        object["version"] = 2
        try JSONSerialization.data(withJSONObject: object).write(to: store.fileURL)
        XCTAssertThrowsError(try store.load())
    }
}
