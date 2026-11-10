import XCTest
@testable import EQCore

final class CalibrationTests: XCTestCase {
    func testSuppliedCommaAndShelfFile() throws {
        let url = Bundle.module.url(forResource: "Beyerdynamic T5 3rd", withExtension: "txt", subdirectory: "Fixtures")!
        let text = try String(contentsOf: url, encoding: .utf8)
        let preset = try APOCodec.parse(text, name: "T5")
        XCTAssertEqual(preset.preampDB, -5)
        XCTAssertEqual(preset.bands.count, 10)
        XCTAssertEqual(preset.bands.map(\.frequency), [105,120,260,390,800,1600,3500,6100,8100,10000])
        XCTAssertEqual(preset.bands.map(\.gainDB), [5.5,-4.1,-7.3,4.2,-3.7,6,-1,-3,-7,-3])
        XCTAssertEqual(preset.bands.map(\.q), [0.71,1.3,0.71,1.3,1,0.71,5,3,4.5,0.71])
        let explicit = try APOCodec.parse(text.replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: " LS ", with: " LSC ").replacingOccurrences(of: " HS ", with: " HSC "), name: "T5")
        let exported = try APOCodec.parse(APOCodec.export(preset), name: "Round trip")
        for rate in [44100.0,48000,96000] {
            for f in [20.0,105,260,1000,10000,19000] {
                XCTAssertEqual(preset.responseDB(at: f, sampleRate: rate), explicit.responseDB(at: f, sampleRate: rate), accuracy: 1e-9)
                XCTAssertEqual(preset.responseDB(at: f, sampleRate: rate), exported.responseDB(at: f, sampleRate: rate), accuracy: 1e-9)
            }
        }
        XCTAssertEqual(try APOCodec.parse("Preamp: -5,0 dB\nFilter 1: ON PK Fc 100,5 Hz Gain 1,2 dB Q 0,710", name: "Decimals").bands[0].frequency,100.5)
        for invalid in ["1,2.3", "1,,2", "nan", "inf", "1e999"] {
            XCTAssertThrowsError(try APOCodec.parse("# header\nPreamp: \(invalid) dB", name: "Bad")) { error in
                XCTAssertTrue(error.localizedDescription.contains("Line 2"))
                XCTAssertTrue(error.localizedDescription.contains(invalid))
            }
            for line in ["Filter 1: ON PK Fc \(invalid) Hz Gain 1 dB Q 1",
                         "Filter 1: ON PK Fc 100 Hz Gain \(invalid) dB Q 1",
                         "Filter 1: ON PK Fc 100 Hz Gain 1 dB Q \(invalid)"] {
                XCTAssertThrowsError(try APOCodec.parse("# header\n" + line, name: "Bad")) { error in
                    XCTAssertTrue(error.localizedDescription.contains("Line 2"))
                    XCTAssertTrue(error.localizedDescription.contains(invalid))
                }
            }
        }
    }

    private func curve() -> CalibrationCurve {
        CalibrationCurve(frequencies: [20,1000,20000], measured: [4,4,4], target: [0,0,0], preampDB: 0, bands: [])
    }
    private func calibrated() -> EQPreset {
        var preset = EQPreset(name: "Synthetic", preampDB: -9, bands: [EQBand(type: .lowShelf, frequency: 100, gainDB: 4, q: 0.71)])
        preset.calibration = CalibrationSettings(measurementID: String(repeating: "a", count: 24))
        return preset
    }

    func testPredictionResidualBypassAndCustomTarget() throws {
        var preset = calibrated()
        let base = try curve().response(preset: preset, sampleRate: 48000, bypassed: false, relative: true)
        XCTAssertEqual(base.before[0], 4)
        XCTAssertGreaterThan(base.after[0], 7.5, "Prediction must retain an incorrect correction, not force flatness")
        let band = EQBand(type: .highShelf, frequency: 4000, gainDB: -3, q: 0.71)
        preset.bands.append(band)
        preset.calibration?.customBandIDs = [band.id]
        preset.calibration?.customTargetEnabled = true
        for rate in [8000.0,44100,48000,96000] {
            // At 8 kHz this enabled shelf is invalid; it must never silently disappear.
            if rate == 8000 { XCTAssertThrowsError(try curve().response(preset: preset, sampleRate: rate, bypassed: false, relative: true)); continue }
            let response = try curve().response(preset: preset, sampleRate: rate, bypassed: false, relative: false)
            let deviation = try curve().response(preset: preset, sampleRate: rate, bypassed: false, relative: true)
            let bypass = try curve().response(preset: preset, sampleRate: rate, bypassed: true, relative: true)
            for i in 0..<response.frequencies.count {
                XCTAssertEqual(response.after[i], 4 + preset.responseDB(at: response.frequencies[i], sampleRate: rate) - preset.preampDB, accuracy: 1e-9)
                XCTAssertEqual(deviation.after[i], response.after[i] - response.target[i], accuracy: 1e-9)
                XCTAssertEqual(bypass.after[i], bypass.before[i], accuracy: 1e-9)
            }
        }
        let active = try curve().response(preset: preset, sampleRate: 48000, bypassed: false, relative: true)
        for i in base.after.indices { XCTAssertEqual(base.after[i], active.after[i], accuracy: 1e-9, "Custom delta belongs in both playback and target") }
        preset.preampDB = -20
        let attenuated = try curve().response(preset: preset, sampleRate: 48000, bypassed: false, relative: true)
        for i in active.after.indices { XCTAssertEqual(active.after[i], attenuated.after[i], accuracy: 1e-9) }
        preset.calibration?.customTargetEnabled = false
        XCTAssertEqual(preset.activeBands.count,1)
        let flatExport = try APOCodec.parse(APOCodec.export(preset), name: "Export")
        XCTAssertFalse(flatExport.bands[1].enabled)
        XCTAssertEqual(flatExport.responseDB(at: 10000, sampleRate: 48000), preset.responseDB(at: 10000, sampleRate: 48000), accuracy: 1e-9)
    }

    func testKnownCorrectionReallyPredictsFlat() throws {
        let preset = calibrated()
        let frequencies = (0...384).map { 20 * pow(1000, Double($0) / 384) }
        let inverse = preset.responseDB(at: frequencies, sampleRate: 48000).map { preset.preampDB - $0 }
        let measurement = CalibrationCurve(frequencies: frequencies, measured: inverse, target: frequencies.map { _ in 0 }, preampDB: 0, bands: [])
        let response = try measurement.response(preset: preset, sampleRate: 48000, bypassed: false, relative: true)
        XCTAssertTrue(response.after.allSatisfy { abs($0) < 1e-9 })
        let restored = try JSONDecoder().decode(EQPreset.self, from: JSONEncoder().encode(preset))
        XCTAssertEqual(restored.calibration, preset.calibration)
    }

    func testMetadataCompatibilityBoundsAndRoundTrip() throws {
        var preset = calibrated()
        let custom = EQBand(type: .peak, frequency: 1200, gainDB: 3, q: 0.2)
        preset.bands.append(custom)
        preset.calibration?.customBandIDs = [custom.id]
        preset.calibration?.customTargetEnabled = true
        let copy = try JSONDecoder().decode(EQPreset.self, from: JSONEncoder().encode(preset))
        XCTAssertEqual(copy,preset)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PresetStore(directory: directory)
        let library = PresetLibrary(presets: [preset], selectedPresetID: preset.id, lastPreset: preset)
        try store.save(library)
        XCTAssertEqual(try PresetStore(directory: directory).load(), library)
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(preset)) as! [String:Any]
        legacy.removeValue(forKey: "calibration")
        XCTAssertNil(try JSONDecoder().decode(EQPreset.self, from: JSONSerialization.data(withJSONObject: legacy)).calibration)
        preset.calibration?.customBandIDs = [UUID()]
        XCTAssertThrowsError(try preset.validate())
        preset = calibrated()
        preset.bands = (0..<32).map { _ in EQBand() }
        try preset.validate()
        preset.bands.append(EQBand())
        XCTAssertThrowsError(try preset.validate())
        let bad = CalibrationCurve(frequencies: [20,20,20000], measured: [0,0,0], target: [0,0,0], preampDB: 0, bands: [])
        XCTAssertThrowsError(try bad.validate())
    }

    func testBundledCalibrationPairsAndRequiredHeadphones() throws {
        let catalog = try CalibrationCatalog.bundled()
        XCTAssertFalse(catalog.isEmpty)
        for name in ["Beyerdynamic T5 (3rd Gen)", "Beyerdynamic DT 990 (fresh earpads)", "Beyerdynamic DT 990 (worn earpads)"] {
            let profile = try XCTUnwrap(catalog.first { $0.name == name })
            let curve = try profile.loadCurve()
            let preset = try profile.preset(curve: curve)
            let result = try curve.response(preset: preset, sampleRate: 48000, bypassed: false, relative: true)
            XCTAssertEqual(result.after.count,385)
            XCTAssertTrue(result.after.allSatisfy(\.isFinite))
            XCTAssertEqual(result.target, Array(repeating: 0.0, count: 385))
        }
        // Every index entry must point at a complete valid curve and playable filter set.
        for profile in catalog { _ = try profile.preset(curve: profile.loadCurve()) }
    }
}
